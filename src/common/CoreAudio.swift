import Foundation
import CoreAudio

// Shared by every tool: configuration, UID lookup and the property accessors.
// Each tool is compiled as `swiftc src/common/*.swift src/<tool>/main.swift`.

enum DuoError: Error, CustomStringConvertible {
    case config(String)
    case deviceUnavailable(String)
    case propertyRead(String, OSStatus)
    case propertyWrite(String, OSStatus)
    case usage(String)

    var description: String {
        switch self {
        case .config(let message): return "config: \(message)"
        case .deviceUnavailable(let uid): return "audio device unavailable: \(uid)"
        case .propertyRead(let property, let status): return "cannot read \(property): \(status)"
        case .propertyWrite(let property, let status): return "cannot write \(property): \(status)"
        case .usage(let text): return "usage: \(text)"
        }
    }
}

func fail(_ message: String) -> Never {
    fputs("\(message)\n", stderr)
    exit(1)
}

// MARK: - Configuration

/// Reads the `KEY="value"` lines of xdr-duo.conf, the file the shell scripts source.
/// Values are taken literally; shell expansion is not supported for the keys read here.
struct DuoConfig {
    static let defaultPath = NSString(string: "~/Library/Application Support/xdr-duo/xdr-duo.conf").expandingTildeInPath

    let xdr1UID: String
    let xdr2UID: String
    let aggregateUID: String
    let aggregateName: String

    var displayUIDs: [String] { [xdr1UID, xdr2UID] }

    static func load() throws -> DuoConfig {
        let path = ProcessInfo.processInfo.environment["XDR_DUO_CONFIG"] ?? defaultPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw DuoError.config("cannot read \(path)")
        }
        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        func required(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else { throw DuoError.config("\(key) missing in \(path)") }
            return value
        }
        return DuoConfig(
            xdr1UID: try required("XDR1_UID"),
            xdr2UID: try required("XDR2_UID"),
            aggregateUID: try required("AGG_UID"),
            aggregateName: try required("AGG_NAME"))
    }

    static func loadOrExit(_ tool: String) -> DuoConfig {
        do { return try load() } catch { fail("\(tool): \(error)") }
    }
}

// MARK: - Aggregate composition

enum DuoComposition {
    /// kAudioAggregateDriftCompensationHighQuality; the header macro is not imported into Swift.
    static let driftQualityHigh = 0x60

    /// XDR 1 is the clock reference, XDR 2 is drift-compensated. Used by ca_agg to build
    /// the aggregate and by ca_multioutcheck to verify it, so both agree by construction.
    static func expectedDrift(_ config: DuoConfig) -> [String: Bool] {
        [config.xdr1UID: false, config.xdr2UID: true]
    }
}

// MARK: - Devices

private func address(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func audioDevice(forUID uid: String) -> AudioDeviceID? {
    // The qualifier is a pointer to the CFString; keeping it in a local var holds the
    // bridged string alive for the whole call.
    var cfUID = uid as CFString
    var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
    }
    return status == 0 && device != 0 ? device : nil
}

func requireDevice(forUID uid: String) throws -> AudioDeviceID {
    guard let device = audioDevice(forUID: uid) else { throw DuoError.deviceUnavailable(uid) }
    return device
}

func deviceUID(_ device: AudioObjectID) -> String? {
    var addr = address(kAudioDevicePropertyDeviceUID)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == 0,
          let uid = value?.takeRetainedValue() else { return nil }
    return uid as String
}

func deviceName(_ device: AudioObjectID) -> String? {
    var addr = address(kAudioObjectPropertyName)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == 0,
          let name = value?.takeRetainedValue() else { return nil }
    return name as String
}

func allDevices() -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == 0 else { return [] }
    return ids
}

func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
    var addr = address(kAudioDevicePropertyNominalSampleRate)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == 0, rate > 0 else { return nil }
    return rate
}

func outputStreamShape(_ device: AudioDeviceID) -> (buffers: Int, channels: Int)? {
    var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == 0,
          Int(size) >= MemoryLayout<AudioBufferList>.size else { return nil }
    var data = Data(count: Int(size))
    return data.withUnsafeMutableBytes { raw in
        var mutableSize = size
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &mutableSize, raw.baseAddress!) == 0 else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.baseAddress!.assumingMemoryBound(to: AudioBufferList.self))
        return (list.count, list.reduce(0) { $0 + Int($1.mNumberChannels) })
    }
}

// MARK: - Volume and mute (output scope, main element)

let volumeAddress = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
let muteAddress = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)

func readVolume(_ device: AudioDeviceID) throws -> Float32 {
    var addr = volumeAddress
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
    guard status == 0 else { throw DuoError.propertyRead("volume", status) }
    return value
}

func writeVolume(_ value: Float32, to device: AudioDeviceID) throws {
    var addr = volumeAddress
    var clamped = min(1, max(0, value))
    let status = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &clamped)
    guard status == 0 else { throw DuoError.propertyWrite("volume", status) }
}

func readMute(_ device: AudioDeviceID) throws -> Bool {
    var addr = muteAddress
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
    guard status == 0 else { throw DuoError.propertyRead("mute", status) }
    return value != 0
}

func writeMute(_ muted: Bool, to device: AudioDeviceID) throws {
    var addr = muteAddress
    var value: UInt32 = muted ? 1 : 0
    let status = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    guard status == 0 else { throw DuoError.propertyWrite("mute", status) }
}
