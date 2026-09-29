import Foundation
import CoreAudio

// Destroys and recreates the stacked "XDR Display Duo" multi-output aggregate.
let config = DuoConfig.loadOrExit("ca_agg")

// Refuse to tear down the existing aggregate when it could not be rebuilt afterwards.
for uid in config.displayUIDs where audioDevice(forUID: uid) == nil {
    fail("ca_agg: subdevice not present: \(uid)")
}

if let old = audioDevice(forUID: config.aggregateUID) {
    let st = AudioHardwareDestroyAggregateDevice(old)
    print("removed existing aggregate: \(st == 0 ? "ok" : "err \(st)")")
}

let drift = DuoComposition.expectedDrift(config)
func subDict(_ uid: String) -> [String: Any] {
    [
        "uid": uid,
        "drift": drift[uid]! ? 1 : 0,
        "drift quality": DuoComposition.driftQualityHigh
    ]
}
// NOTE: header macros not imported in Swift as symbols; literal keys used here.
// No "master" key on purpose: with an explicit master, stereo reached only one display.
let spec: [String: Any] = [
    "name": config.aggregateName,
    "uid": config.aggregateUID,
    "private": false,
    "stacked": true,   // Multi-Output: fan the same stream out to every subdevice
    "subdevices": config.displayUIDs.map(subDict)
]
var newID = AudioDeviceID(0)
let st = AudioHardwareCreateAggregateDevice(spec as CFDictionary, &newID)
guard st == 0 else { fail("CREATE_ERR \(st)") }
print("created aggregate id=\(newID)")
