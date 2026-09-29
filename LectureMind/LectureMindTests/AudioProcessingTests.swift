import XCTest
@testable import LectureMind

final class AudioProcessingTests: XCTestCase {
    func testWAVHeaderDescribes16kHzMonoPCM() {
        let samples: [Int16] = [0, 1, -1, Int16.max, Int16.min]
        let data = AudioProcessing.wavData(samples: samples, sampleRate: 16_000)

        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(uint32(data, at: 4), UInt32(36 + samples.count * 2))
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(uint32(data, at: 16), 16)          // fmt chunk size
        XCTAssertEqual(uint16(data, at: 20), 1)           // PCM
        XCTAssertEqual(uint16(data, at: 22), 1)           // mono
        XCTAssertEqual(uint32(data, at: 24), 16_000)      // sample rate
        XCTAssertEqual(uint32(data, at: 28), 32_000)      // byte rate
        XCTAssertEqual(uint16(data, at: 32), 2)           // block align
        XCTAssertEqual(uint16(data, at: 34), 16)          // bits per sample
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(uint32(data, at: 40), UInt32(samples.count * 2))
    }

    func testWAVSamplesAreLittleEndian() {
        let data = AudioProcessing.wavData(samples: [0x0102, -2], sampleRate: 16_000)
        XCTAssertEqual(Array(data[44..<48]), [0x02, 0x01, 0xFE, 0xFF])
    }

    func testEmptyWAVIsValidHeaderOnly() {
        let data = AudioProcessing.wavData(samples: [], sampleRate: 16_000)
        XCTAssertEqual(data.count, 44)
        XCTAssertEqual(uint32(data, at: 40), 0)
    }

    func testNormalizedLevel() {
        XCTAssertEqual(AudioProcessing.normalizedLevel(of: [Int16]()), 0)
        XCTAssertEqual(AudioProcessing.normalizedLevel(of: [Int16](repeating: 0, count: 100)), 0)
        // A constant 10% of full scale is -20 dBFS, which maps to 40/60 on the meter.
        XCTAssertEqual(AudioProcessing.normalizedLevel(of: [Int16](repeating: 3277, count: 100)), 2.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(AudioProcessing.normalizedLevel(of: [Int16](repeating: Int16.min, count: 100)), 1, accuracy: 0.001)
        // Below the -60 dBFS floor.
        XCTAssertEqual(AudioProcessing.normalizedLevel(of: [Int16](repeating: 1, count: 100)), 0)
    }

    func testPeakAmplitudeHandlesInt16Min() {
        XCTAssertEqual(AudioProcessing.peakAmplitude(of: [Int16]()), 0)
        XCTAssertEqual(AudioProcessing.peakAmplitude(of: [3, -7, 5]), 7)
        XCTAssertEqual(AudioProcessing.peakAmplitude(of: [Int16.min, 12]), 32_768)
    }

    func testQuietestSplitIndexLandsInPause() {
        var samples = [Int16](repeating: 12_000, count: 2_000)
        for index in 1_000..<1_320 {
            samples[index] = 0
        }
        let split = AudioProcessing.quietestSplitIndex(in: samples, searchRange: 0..<2_000, frameLength: 160)
        XCTAssertTrue((1_000..<1_320).contains(split), "split \(split) is outside the pause")
    }

    func testQuietestSplitIndexPrefersLatestOfEquallyQuietWindows() {
        let samples = [Int16](repeating: 0, count: 1_000)
        let split = AudioProcessing.quietestSplitIndex(in: samples, searchRange: 200..<1_000, frameLength: 100)
        XCTAssertEqual(split, 950)
    }

    func testQuietestSplitIndexFallsBackToRangeEnd() {
        let samples = [Int16](repeating: 100, count: 50)
        XCTAssertEqual(AudioProcessing.quietestSplitIndex(in: samples, searchRange: 0..<50, frameLength: 160), 50)
        XCTAssertEqual(AudioProcessing.quietestSplitIndex(in: samples, searchRange: 0..<500, frameLength: 0), 50)
    }

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
}
