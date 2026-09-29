import Foundation
import CoreAudio

// Verifies the aggregate invariants documented in README.md; exit 0 only for a valid composition.
let config = DuoConfig.loadOrExit("ca_multioutcheck")
let uid = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : config.aggregateUID

func composition(_ device: AudioDeviceID) -> NSDictionary? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyComposition,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFDictionary>?
    var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == 0,
          let dictionary = value?.takeRetainedValue() else { return nil }
    return dictionary as NSDictionary
}

func activeSubdeviceUIDs(_ device: AudioDeviceID) -> [String]? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == 0 else { return nil }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == 0 else { return nil }
    return ids.map { deviceUID($0) ?? "?" }
}

guard let device = audioDevice(forUID: uid),
      let dictionary = composition(device),
      let shape = outputStreamShape(device),
      let active = activeSubdeviceUIDs(device) else {
    print("FAIL: unable to inspect \(uid)")
    exit(1)
}

let stacked = (dictionary["stacked"] as? NSNumber)?.boolValue == true
let hasMaster = dictionary["master"] != nil
let membersOK = Set(active) == Set(config.displayUIDs) && active.count == 2

// Invariants 6 and 7: XDR 1 without, XDR 2 with high-quality drift compensation.
let subdevices = dictionary["subdevices"] as? [NSDictionary] ?? []
let expectedDrift = DuoComposition.expectedDrift(config)
let driftOK = expectedDrift.allSatisfy { uid, drift in
    guard let sub = subdevices.first(where: { $0["uid"] as? String == uid }) else { return false }
    let actual = (sub["drift"] as? NSNumber)?.boolValue == true
    let quality = (sub["drift quality"] as? NSNumber)?.intValue
    return actual == drift && (!drift || quality == DuoComposition.driftQualityHigh)
}

let valid = stacked && !hasMaster && shape.buffers == 1 && shape.channels == 2 && membersOK && driftOK
let summary = "stacked=\(stacked ? 1 : 0) master=\(hasMaster ? "present" : "none") buffers=\(shape.buffers) channels=\(shape.channels) activeSubdevices=\(active.count) members=\(membersOK ? "ok" : "wrong") drift=\(driftOK ? "ok" : "wrong")"
print(valid ? "PASS: \(summary)" : "FAIL: \(summary)")
exit(valid ? 0 : 1)
