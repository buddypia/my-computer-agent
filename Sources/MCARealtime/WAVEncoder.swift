import Foundation

/// Utility to encode raw PCM audio data into a standard RIFF/WAV format container.
///
/// Gemini API accepts audio formats such as `audio/wav` with embedded inline data.
/// Having an explicit WAV header guarantees the model knows the exact sample rate,
/// channel count, and bit depth without relying on heuristics or transport header parameters.
public enum WAVEncoder {
    /// Encodes 16-bit signed integer linear PCM data into a RIFF/WAV file format.
    ///
    /// - Parameters:
    ///   - pcmData: Raw 16-bit little-endian PCM audio bytes.
    ///   - sampleRate: Sampling rate in Hz (e.g. 16,000 Hz).
    ///   - channels: Number of channels (default: 1 for mono).
    /// - Returns: Complete WAV file data including standard 44-byte header.
    public static func encode(
        pcmData: Data,
        sampleRate: Int = 16_000,
        channels: Int = 1
    ) -> Data {
        let bitsPerSample: Int = 16
        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let chunkSize = 36 + dataSize

        var data = Data(capacity: 44 + pcmData.count)

        // RIFF chunk descriptor
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: chunkSize.littleEndianBytes)
        data.append(contentsOf: "WAVE".utf8)

        // "fmt " sub-chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: UInt32(16).littleEndianBytes) // Subchunk1Size for PCM
        data.append(contentsOf: UInt16(1).littleEndianBytes)  // AudioFormat 1 = PCM
        data.append(contentsOf: UInt16(channels).littleEndianBytes)
        data.append(contentsOf: UInt32(sampleRate).littleEndianBytes)
        data.append(contentsOf: UInt32(byteRate).littleEndianBytes)
        data.append(contentsOf: UInt16(blockAlign).littleEndianBytes)
        data.append(contentsOf: UInt16(bitsPerSample).littleEndianBytes)

        // "data" sub-chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: dataSize.littleEndianBytes)
        data.append(pcmData)

        return data
    }

    /// Resamples and encodes Float32 samples into a 16kHz mono WAV container.
    ///
    /// - Parameters:
    ///   - samples: Raw input audio samples (Float32 in range [-1.0, 1.0]).
    ///   - sourceRate: Source sample rate in Hz.
    ///   - targetRate: Desired sample rate (default: 16,000 Hz).
    /// - Returns: Encoded WAV data ready for Gemini transmission.
    public static func encodeFloat32Samples(
        _ samples: [Float],
        sourceRate: Double,
        targetRate: Double = 16_000
    ) -> Data {
        guard !samples.isEmpty else { return Data() }
        let resampled = PCMConverter.resample(samples, from: sourceRate, to: targetRate)
        let int16Data = PCMConverter.float32ToInt16(resampled)
        return encode(pcmData: int16Data, sampleRate: Int(targetRate), channels: 1)
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian) { Array($0) }
    }
}
