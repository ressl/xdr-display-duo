import Foundation
import CoreAudio

// Prints the device ID and output channel count; exits 1 when the UID is not present.
guard CommandLine.arguments.count == 2 else { fail("usage: ca_layout <device-uid>") }
let uid = CommandLine.arguments[1]
guard let dev = audioDevice(forUID: uid) else { fail("uid not found: \(uid)") }
let channels = outputStreamShape(dev)?.channels ?? -1
print("id=\(dev) uid=\(uid) -> output channels: \(channels)")
