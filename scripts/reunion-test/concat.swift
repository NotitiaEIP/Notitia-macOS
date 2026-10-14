// Concatène les répliques (.aiff) et les silences (.silence, durée en secondes) d'un dossier en un fichier AAC mono.
// Usage : concat <dossier> <sortie.m4a>
import AVFoundation
let dir = URL(filePath: CommandLine.arguments[1])
let out = URL(filePath: CommandLine.arguments[2])
let rate = 22050.0
let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
var samples: [Float] = []
func silence(_ s: Double) { samples += [Float](repeating: 0, count: Int(s * rate)) }
silence(0.8)
for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where name.hasSuffix(".aiff") || name.hasSuffix(".silence") {
    let url = dir.appending(path: name)
    if name.hasSuffix(".silence") { silence(Double(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!); continue }
    let file = try AVAudioFile(forReading: url)
    let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: input)
    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * rate / file.processingFormat.sampleRate) + 1024)!
    var done = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if done { status.pointee = .endOfStream; return nil }
        done = true; status.pointee = .haveData; return input
    }
    samples += Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    silence(0.7)
}
silence(1.0)
try? FileManager.default.removeItem(at: out)
let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
let writer = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
buffer.frameLength = AVAudioFrameCount(samples.count)
try writer.write(from: buffer)
writer.close()
print(String(format: "Durée : %.0f s", Double(samples.count) / rate))
