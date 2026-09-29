import Foundation
import CoreAudio

// Makes the device with the given UID the default output.
guard CommandLine.arguments.count == 2 else { fail("usage: ca_setout <device-uid>") }
let uid = CommandLine.arguments[1]
guard var dev = audioDevice(forUID: uid) else { fail("uid not found: \(uid)") }
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
guard st == 0 else { fail("SET_ERR \(st)") }
print("default output set -> id=\(dev)")
