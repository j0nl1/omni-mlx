import Foundation
import AudioCore

/// Spools mono PCM16 with a bounded size instead of retaining generated tensors.
final class PCMWriter {
    private let file: FileHandle
    private let sampleRate: Int
    private let maxBytes: Int
    private let maxFrames: Int
    private var frames = 0
    init(url: URL, sampleRate: Int, maxBytes: Int, maxSeconds: Double) throws {
        self.sampleRate = sampleRate; self.maxBytes = maxBytes; maxFrames = Int(maxSeconds * Double(sampleRate))
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ServiceError("audio_write_failed", "Cannot create the audio result.", status: 500) }
        file = try FileHandle(forWritingTo: url)
        try file.write(contentsOf: Data(repeating: 0, count: 44))
    }
    func append(_ samples: [Float]) throws {
        guard frames + samples.count <= maxFrames, 44 + (frames + samples.count) * 2 <= maxBytes else {
            throw ServiceError("output_too_large", "Generated audio exceeds its duration or byte limit.", status: 413)
        }
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            guard sample.isFinite else { throw ServiceError("invalid_audio_output", "The model generated a non-finite audio sample.", status: 502) }
            var value = Int16((max(-1, min(1, sample)) * 32767).rounded()).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        try file.write(contentsOf: data); frames += samples.count
    }
    func finish() throws {
        guard frames > 0 else { throw ServiceError("empty_audio_output", "The model generated no audio.", status: 502) }
        var header = Data()
        func text(_ value: String) { header.append(Data(value.utf8)) }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + frames * 2)); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16); text("data"); u32(UInt32(frames * 2))
        try file.seek(toOffset: 0); try file.write(contentsOf: header); try file.close()
    }
    deinit { try? file.close() }
}
