import Foundation
import CoreAudio
import AppKit
import CoreGraphics

private let volumeStep: Float32 = 1.0 / 16.0
/// Rapid key presses reuse the last computed target only within this window, so a stale
/// target from an earlier session can never override the devices' current values.
private let targetCacheLifetime: TimeInterval = 1.5
/// After a media key the helper writes both displays itself; the mirror stands back for this
/// long so it cannot copy the native single-device change first and cancel the key's effect.
private let keyQuietPeriod: TimeInterval = 0.5
/// Device quantization differs by a few thousandths; larger differences count as out of sync.
private let syncTolerance: Float32 = 0.01
private let systemDefinedEventType = CGEventType(rawValue: 14)!
/// NX_SUBTYPE_AUX_CONTROL_BUTTONS: the only systemDefined subtype whose data1 carries media keys.
private let auxControlButtonsSubtype = 8
/// Name CoreAudio reports for the speaker device of a Studio Display XDR.
private let xdrSpeakerName = "Studio Display XDR Speakers"
private let usage = "xdr-volume list [--xdr] | get | raw | set 0-100 | up | down | mute | device 1|2 getvol|setvol 0.0-1.0|getmute|setmute 0|1 | decode <data1> [subtype] | listen | listen --request-permission"

private func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime])
    print("\(stamp) \(message)")
    fflush(stdout)
}

private func percent(_ scalar: Float32) -> Int { Int((scalar * 100).rounded()) }

private struct DisplayPair {
    let first: AudioDeviceID
    let second: AudioDeviceID

    init(_ config: DuoConfig) throws {
        first = try requireDevice(forUID: config.xdr1UID)
        second = try requireDevice(forUID: config.xdr2UID)
    }

    var devices: [AudioDeviceID] { [first, second] }

    func rawState() throws -> (firstVolume: Float32, secondVolume: Float32, firstMuted: Bool, secondMuted: Bool) {
        (try readVolume(first), try readVolume(second), try readMute(first), try readMute(second))
    }

    func state() throws -> (volume: Float32, muted: Bool) {
        let raw = try rawState()
        return ((raw.firstVolume + raw.secondVolume) / 2, raw.firstMuted && raw.secondMuted)
    }

    func set(volume: Float32) throws {
        try writeVolume(volume, to: first)
        try writeVolume(volume, to: second)
        try set(muted: false)
    }

    func set(muted: Bool) throws {
        try writeMute(muted, to: first)
        try writeMute(muted, to: second)
    }

    func toggleMute() throws {
        let target = !(try readMute(first) && readMute(second))
        try set(muted: target)
    }
}

private enum MediaAction: String {
    case up
    case down
    case mute
}

private func decodeMediaKey(subtype: Int, data1: Int) -> MediaAction? {
    guard subtype == auxControlButtonsSubtype else { return nil }
    let keyType = (data1 & 0xffff0000) >> 16
    let keyState = (data1 & 0x0000ff00) >> 8
    guard keyState == 0x0a else { return nil }
    switch keyType {
    case 0: return .up
    case 1: return .down
    case 7: return .mute
    default: return nil
    }
}

/// Owns everything that touches the two displays in `listen` mode. Media keys and the
/// volume/mute mirror run on one serial queue, so they can never interleave half-way.
private final class DuoController {
    private let config: DuoConfig
    private let queue = DispatchQueue(label: "com.ressl.xdr-volume-keys")
    private var targetVolume: Float32?
    private var targetMuted: Bool?
    private var targetTime: TimeInterval = 0
    private var listeners: [(device: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var pairAvailable: Bool?
    private var deferredMirror = Set<Int>()
    private let keyLock = NSLock()
    private var lastKeyUptime = -TimeInterval.infinity
    var eventTap: CFMachPort?

    init(config: DuoConfig) {
        self.config = config
    }

    // MARK: Media keys

    func handle(_ action: MediaAction) {
        keyLock.lock()
        lastKeyUptime = ProcessInfo.processInfo.systemUptime
        keyLock.unlock()
        queue.async {
            do {
                let displays = try DisplayPair(self.config)
                let raw = try displays.rawState()
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.targetTime > targetCacheLifetime {
                    self.targetVolume = nil
                    self.targetMuted = nil
                }
                if abs(raw.firstVolume - raw.secondVolume) < syncTolerance {
                    self.targetVolume = (raw.firstVolume + raw.secondVolume) / 2
                }
                if raw.firstMuted == raw.secondMuted {
                    self.targetMuted = raw.firstMuted
                }

                switch action {
                case .up, .down:
                    let fallback = action == .up
                        ? min(raw.firstVolume, raw.secondVolume)
                        : max(raw.firstVolume, raw.secondVolume)
                    let current = self.targetVolume ?? fallback
                    let delta: Float32 = action == .up ? volumeStep : -volumeStep
                    let target = min(1, max(0, current + delta))
                    self.targetVolume = target
                    self.targetMuted = false
                    // The event tap does not swallow the key; let the native single-device
                    // change land first so this write wins.
                    Thread.sleep(forTimeInterval: 0.08)
                    try displays.set(volume: target)
                case .mute:
                    let current = self.targetMuted ?? raw.secondMuted
                    let target = !current
                    self.targetMuted = target
                    Thread.sleep(forTimeInterval: 0.08)
                    try displays.set(muted: target)
                }
                self.targetTime = ProcessInfo.processInfo.systemUptime
                let state = try displays.state()
                log("media-key=\(action.rawValue) volume=\(percent(state.volume)) mute=\(state.muted ? 1 : 0)")
            } catch {
                log("media-key=\(action.rawValue) error: \(error)")
            }
        }
    }

    // MARK: Mirror

    /// Replaces the former 2-second polling mirror: CoreAudio notifies on every volume or
    /// mute change of either display, and the changed display's value is copied to the other.
    func startMirror() {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // Device IDs change when a display is unplugged and reattached.
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, queue) { [weak self] _, _ in
            self?.rewatch()
        }
        if status != 0 { log("mirror: cannot watch device list: \(status)") }
        queue.async { self.rewatch() }
    }

    private func rewatch() {
        for listener in listeners {
            var address = listener.address
            _ = AudioObjectRemovePropertyListenerBlock(listener.device, &address, queue, listener.block)
        }
        listeners.removeAll()

        let displays: DisplayPair
        do {
            displays = try DisplayPair(config)
        } catch {
            if pairAvailable != false { log("mirror: waiting for both displays (\(error))") }
            pairAvailable = false
            return
        }
        for (index, device) in displays.devices.enumerated() {
            for property in [volumeAddress, muteAddress] {
                var address = property
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    self?.mirror(from: index)
                }
                let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
                if status == 0 {
                    listeners.append((device, property, block))
                } else {
                    log("mirror: cannot watch xdr\(index + 1): \(status)")
                }
            }
        }
        if pairAvailable != true { log("mirror: watching both displays") }
        pairAvailable = true
        // Resolve any divergence that arose while not watching, with XDR 1 as reference.
        mirror(from: 0)
    }

    /// Copies volume and mute from the display at `source` to the other one if they differ.
    /// Reads current values rather than trusting the notification order, so the helper's own
    /// writes (which also notify) resolve to no-ops.
    private func mirror(from source: Int) {
        keyLock.lock()
        let quietRemaining = keyQuietPeriod - (ProcessInfo.processInfo.systemUptime - lastKeyUptime)
        keyLock.unlock()
        if quietRemaining > 0 {
            // Re-check afterwards, so a failed key-handler write still converges.
            if deferredMirror.insert(source).inserted {
                queue.asyncAfter(deadline: .now() + quietRemaining) {
                    self.deferredMirror.remove(source)
                    self.mirror(from: source)
                }
            }
            return
        }
        do {
            let displays = try DisplayPair(config)
            let from = displays.devices[source]
            let to = displays.devices[1 - source]
            let volume = try readVolume(from)
            if abs(volume - (try readVolume(to))) >= syncTolerance {
                try writeVolume(volume, to: to)
                log("mirror: volume=\(percent(volume)) xdr\(source + 1) -> xdr\(2 - source)")
            }
            let muted = try readMute(from)
            if muted != (try readMute(to)) {
                try writeMute(muted, to: to)
                log("mirror: mute=\(muted ? 1 : 0) xdr\(source + 1) -> xdr\(2 - source)")
            }
        } catch {
            log("mirror: \(error)")
        }
    }
}

private let mediaKeyCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<DuoController>.fromOpaque(userInfo).takeUnretainedValue()

    // macOS disables a tap that is too slow or while secure input is active. The process
    // keeps running in that case, so launchd's KeepAlive would never recover it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = controller.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        log("event tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
        return Unmanaged.passUnretained(event)
    }

    guard type == systemDefinedEventType,
          let nsEvent = NSEvent(cgEvent: event),
          let action = decodeMediaKey(subtype: Int(nsEvent.subtype.rawValue), data1: nsEvent.data1) else {
        return Unmanaged.passUnretained(event)
    }
    controller.handle(action)
    return Unmanaged.passUnretained(event)
}

private func installEventTap(_ controller: DuoController) -> Bool {
    let userInfo = Unmanaged.passUnretained(controller).toOpaque()
    let mask = CGEventMask(1) << systemDefinedEventType.rawValue
    guard let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: mediaKeyCallback,
        userInfo: userInfo) else {
        return false
    }
    controller.eventTap = eventTap
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    log("listening for F11/F12/Mute")
    return true
}

private func listen(config: DuoConfig) -> Never {
    // Lives for the whole process; the event tap and CoreAudio blocks reference it.
    let controller = DuoController(config: config)
    controller.startMirror()

    // Without Input Monitoring the mirror still runs. The permission is evaluated once per
    // process, so a later grant only takes effect in a new one: exit after a minute and let
    // launchd's KeepAlive start a fresh listener.
    if !CGPreflightListenEventAccess() {
        log("Input Monitoring permission is required for media keys; mirror is running, restarting in 60 s to re-check")
    }
    if !(CGPreflightListenEventAccess() && installEventTap(controller)) {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
            log("restarting to re-check Input Monitoring permission")
            exit(0)
        }
    }
    CFRunLoopRun()
    exit(0)
}

private func runDeviceCommand(_ config: DuoConfig, _ arguments: [String]) throws {
    guard arguments.count >= 3, let index = Int(arguments[1]), index == 1 || index == 2 else {
        throw DuoError.usage(usage)
    }
    let device = try requireDevice(forUID: config.displayUIDs[index - 1])
    switch (arguments[2], arguments.count) {
    case ("getvol", 3):
        print(String(format: "%.4f", try readVolume(device)))
    case ("setvol", 4):
        guard let value = Float32(arguments[3]), (0...1).contains(value) else { throw DuoError.usage(usage) }
        try writeVolume(value, to: device)
        print(String(format: "%.4f", try readVolume(device)))
    case ("getmute", 3):
        print(try readMute(device) ? 1 : 0)
    case ("setmute", 4):
        guard arguments[3] == "0" || arguments[3] == "1" else { throw DuoError.usage(usage) }
        try writeMute(arguments[3] == "1", to: device)
        print(try readMute(device) ? 1 : 0)
    default:
        throw DuoError.usage(usage)
    }
}

private func runCommand(_ arguments: [String]) throws {
    guard let command = arguments.first else { throw DuoError.usage(usage) }

    if command == "decode" {
        guard (2...3).contains(arguments.count), let data1 = Int(arguments[1]) else { throw DuoError.usage(usage) }
        let subtype = arguments.count == 3 ? Int(arguments[2]) : auxControlButtonsSubtype
        guard let subtype else { throw DuoError.usage(usage) }
        print(decodeMediaKey(subtype: subtype, data1: data1)?.rawValue ?? "ignore")
        return
    }

    if command == "list" {
        // Needs no config: used to find the UIDs before one exists.
        let onlyXDR = arguments.dropFirst().elementsEqual(["--xdr"])
        guard arguments.count == 1 || onlyXDR else { throw DuoError.usage(usage) }
        var rows: [(uid: String, channels: Int, name: String)] = []
        for device in allDevices() {
            guard let uid = deviceUID(device), let channels = outputStreamShape(device)?.channels, channels > 0 else { continue }
            rows.append((uid, channels, deviceName(device) ?? "?"))
        }
        for row in rows.sorted(by: { $0.uid < $1.uid }) {
            if onlyXDR {
                if row.name == xdrSpeakerName { print(row.uid) }
            } else {
                print("\(row.uid)\t\(row.channels) out\t\(row.name)")
            }
        }
        return
    }

    let config = try DuoConfig.load()
    if command == "listen" {
        // Only asks for Input Monitoring and exits; `open -n` must not leave a second listener
        // running next to the LaunchAgent, or every key would be applied twice.
        if arguments.contains("--request-permission") {
            print(CGRequestListenEventAccess() ? "Input Monitoring granted" : "Input Monitoring requested")
            return
        }
        listen(config: config)
    }
    if command == "device" {
        try runDeviceCommand(config, arguments)
        return
    }

    let displays = try DisplayPair(config)
    switch command {
    case "get":
        let current = try displays.state()
        print("volume=\(percent(current.volume)) mute=\(current.muted ? 1 : 0)")
    case "raw":
        let raw = try displays.rawState()
        print(String(format: "xdr1 volume=%.4f mute=%d", raw.firstVolume, raw.firstMuted ? 1 : 0))
        print(String(format: "xdr2 volume=%.4f mute=%d", raw.secondVolume, raw.secondMuted ? 1 : 0))
    case "set":
        guard arguments.count == 2, let value = Int(arguments[1]), (0...100).contains(value) else {
            throw DuoError.usage(usage)
        }
        try displays.set(volume: Float32(value) / 100)
        try runCommand(["get"])
    case "up", "down":
        let current = try displays.state().volume
        let delta = command == "up" ? volumeStep : -volumeStep
        try displays.set(volume: current + delta)
        try runCommand(["get"])
    case "mute":
        try displays.toggleMute()
        try runCommand(["get"])
    default:
        throw DuoError.usage(usage)
    }
}

do {
    try runCommand(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("xdr-volume: \(error)\n", stderr)
    exit(1)
}
