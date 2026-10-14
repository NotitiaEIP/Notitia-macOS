@preconcurrency import AVFoundation
import Foundation

/// Lit un fichier audio et le découpe en `AudioChunk` mono, horodatés comme ceux du micro.
/// Permet de faire passer un fichier par les mêmes analyses qu'un enregistrement (transcription, sons, volume).
public enum AudioFileReader {
    public static func chunks(of url: URL, chunkSize: Int = 4096) throws -> (chunks: [AudioChunk], duration: TimeInterval) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        // Un seul `read` peut s'arrêter avant la fin du fichier : on lit jusqu'au bout.
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { break }
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            samples += UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        }
        let chunks = stride(from: 0, to: samples.count, by: chunkSize).map { offset in
            AudioChunk(samples: Array(samples[offset..<min(offset + chunkSize, samples.count)]),
                       sampleRate: format.sampleRate,
                       time: Double(offset) / format.sampleRate)
        }
        return (chunks, Double(samples.count) / format.sampleRate)
    }

    /// Flux prêt à passer à un `TranscriptionEngine` ou un `AnnotationDetector`.
    public static func stream(_ chunks: [AudioChunk]) -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            chunks.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}
