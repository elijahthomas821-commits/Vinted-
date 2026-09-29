import Foundation

/// Pure helpers for the 16 kHz mono 16-bit PCM pipeline. They are deliberately free of
/// ScreenCaptureKit and AVFoundation types so they can be unit tested directly.
enum AudioProcessing {
    /// Whisper resamples everything to 16 kHz mono internally, so capturing at that rate keeps
    /// uploads small (~1 MB per 30 s) without losing accuracy.
    static let targetSampleRate = 16_000

    /// Encodes samples as a canonical RIFF/WAVE file (44-byte header, little-endian PCM).
    static func wavData(samples: [Int16], sampleRate: Int, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * MemoryLayout<Int16>.size

        var data = Data(capacity: 44 + dataSize)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))                       // fmt chunk size for PCM
        data.appendLittleEndian(UInt16(1))                        // format tag: linear PCM
        data.appendLittleEndian(UInt16(channels))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * blockAlign))  // byte rate
        data.appendLittleEndian(UInt16(blockAlign))
        data.appendLittleEndian(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(UInt32(dataSize))
        samples.map(\.littleEndian).withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// RMS level of `samples` mapped onto 0...1 with a -60 dBFS floor, for the level meter.
    static func normalizedLevel<C: Collection>(of samples: C) -> Float where C.Element == Int16 {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares = 0.0
        for sample in samples {
            let value = Double(sample) / 32_768
            sumOfSquares += value * value
        }
        let rms = (sumOfSquares / Double(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return Float(min(max((decibels + 60) / 60, 0), 1))
    }

    static func peakAmplitude<C: Collection>(of samples: C) -> Int where C.Element == Int16 {
        samples.reduce(0) { max($0, abs(Int($1))) }
    }

    /// Chooses where to cut a chunk so the boundary falls in the quietest `frameLength`-sample
    /// window inside `searchRange`. Cutting in a pause rather than at a fixed offset avoids
    /// splitting a word across two transcription requests. Returns the index of the first
    /// sample of the next chunk.
    static func quietestSplitIndex(in samples: [Int16], searchRange: Range<Int>, frameLength: Int) -> Int {
        let lower = max(searchRange.lowerBound, 0)
        let upper = min(searchRange.upperBound, samples.count)
        guard frameLength > 0, upper - lower >= frameLength else { return upper }

        var bestIndex = upper
        var bestEnergy = Int64.max
        var frameStart = lower
        while frameStart + frameLength <= upper {
            var energy: Int64 = 0
            for index in frameStart..<(frameStart + frameLength) {
                let value = Int64(samples[index])
                energy += value * value
            }
            // `<=` prefers the latest of equally quiet windows, keeping chunks close to full length.
            if energy <= bestEnergy {
                bestEnergy = energy
                bestIndex = frameStart + frameLength / 2
            }
            frameStart += frameLength
        }
        return bestIndex
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
