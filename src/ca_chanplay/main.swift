import Foundation
import CoreAudio

// Diagnostic: plays a 2.5 s test tone on one channel pair of the given device.
final class Shared { var frame = 0; let targetCh: Int; let rate: Double; init(_ c: Int, _ r: Double) { targetCh = c; rate = r } }
guard CommandLine.arguments.count == 3, let ch = Int(CommandLine.arguments[2]), ch >= 0 else {
    fail("usage: ca_chanplay <device-uid> <first-channel-of-pair>")
}
let uid = CommandLine.arguments[1]
guard let dev = audioDevice(forUID: uid) else { fail("uid not found: \(uid)") }
let rate = nominalSampleRate(dev) ?? 48000
let durationFrames = Int(rate * 2.5)
let shared = Shared(ch, rate)
var procID: AudioDeviceIOProcID?
let cb: AudioDeviceIOProc = { (_, _, _, _, outData, _, _) -> OSStatus in
    let abl = UnsafeMutableAudioBufferListPointer(outData)
    var framesWritten = 0
    for buf in abl {
        guard let mData = buf.mData, buf.mNumberChannels > 0 else { continue }
        let data = mData.assumingMemoryBound(to: Float.self)
        let nch = Int(buf.mNumberChannels)
        let frames = Int(buf.mDataByteSize) / (nch * MemoryLayout<Float>.size)
        let start = shared.frame
        let target = shared.targetCh
        for f in 0..<frames {
            let n = start + f
            let t = Double(n) / shared.rate
            // 100 ms fade-in, 250 ms fade-out at the end of the tone.
            let env = min(1.0, Double(n) / (shared.rate * 0.1)) * max(0, min(1.0, Double(durationFrames - n) / (shared.rate * 0.25)))
            let s = Float(env * 0.25 * sin(2 * Double.pi * (330 + Double(target) * 110) * t))
            for c in 0..<nch { data[f * nch + c] = (c == target || c == target + 1) ? s : 0 }
        }
        framesWritten = max(framesWritten, frames)
    }
    shared.frame += framesWritten
    return noErr
}
let st1 = AudioDeviceCreateIOProcID(dev, cb, nil, &procID)
let st2 = AudioDeviceStart(dev, procID)
Thread.sleep(forTimeInterval: 2.5)
let st3 = AudioDeviceStop(dev, procID)
if let procID { AudioDeviceDestroyIOProcID(dev, procID) }
print("create=\(st1) start=\(st2) stop=\(st3) pair-ch=\(ch) rate=\(rate)")
