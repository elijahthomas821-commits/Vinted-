import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

/// A finished slice of captured audio, written to disk as 16 kHz mono 16-bit WAV.
struct AudioChunk: Sendable, Equatable {
    let index: Int
    let fileURL: URL
    /// Offset of the chunk's first sample from the start of the recording.
    let startTime: TimeInterval
    let duration: TimeInterval
}

/// Out-of-band notifications from the capture pipeline.
enum CaptureEvent: Sendable, Equatable {
    /// Recent loudness, 0...1, delivered roughly ten times per second.
    case level(Float)
    case warning(String)
    /// The system ended the capture, e.g. the user stopped sharing from the menu bar.
    case stoppedUnexpectedly(String)
}

enum AudioCaptureError: LocalizedError {
    case permissionDenied
    case noDisplayAvailable
    case alreadyRunning
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "LectureMind needs Screen & System Audio Recording permission. Enable it in System Settings › Privacy & Security, then relaunch LectureMind."
        case .noDisplayAvailable:
            return "No display is available to capture system audio from."
        case .alreadyRunning:
            return "A recording is already in progress."
        case .captureFailed(let details):
            return "Could not start capturing system audio: \(details)"
        }
    }
}

/// The capture pipeline as seen by `AppState`, so tests can substitute a fake.
protocol AudioCapturing: AnyObject {
    func hasScreenCapturePermission() -> Bool
    @discardableResult func requestScreenCapturePermission() -> Bool
    /// Starts capturing system audio and returns the stream of finished chunks. The stream
    /// finishes after `stop()` has flushed the final partial chunk.
    @MainActor func start(onEvent: @escaping @Sendable (CaptureEvent) -> Void) async throws -> AsyncStream<AudioChunk>
    @MainActor func stop() async
    /// Deletes chunk files left on disk by finished or crashed sessions.
    func removeTemporaryFiles()
}

/// Records everything the Mac plays through its speakers using ScreenCaptureKit (no virtual
/// audio drivers), converts it to 16 kHz mono PCM, and writes it out in ~30 second WAV chunks.
///
/// Threading: `start()`/`stop()` run on the main actor and are the only code touching `captureStream`.
/// Sample buffers arrive on `audioQueue`, which exclusively owns `session`, so the conversion
/// and chunking state needs no locks.
final class AudioCaptureManager: NSObject, AudioCapturing, @unchecked Sendable {
    private let chunkSampleCount: Int
    /// How far back from the nominal chunk end to look for a pause to cut at.
    private let boundarySearchSampleCount: Int
    /// Chunks whose loudest sample stays below this are skipped: Whisper tends to hallucinate
    /// text ("Thanks for watching!") on silence, and skipping saves API calls.
    private let silencePeakThreshold: Int
    /// Whisper rejects clips shorter than 0.1 s; anything under half a second is noise anyway.
    private let minimumChunkSampleCount = AudioProcessing.targetSampleRate / 2

    private let outputFormat: AVAudioFormat
    private let logger = Logger(subsystem: "com.lecturemind.app", category: "AudioCapture")
    private let audioQueue = DispatchQueue(label: "com.lecturemind.audio-capture", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.lecturemind.video-discard", qos: .background)

    private var captureStream: SCStream?   // main actor only
    private var session: Session?   // audioQueue only

    static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LectureMind", isDirectory: true)
    }

    init(chunkDuration: TimeInterval = 30, silenceThresholdDBFS: Double = -50) {
        let rate = Double(AudioProcessing.targetSampleRate)
        chunkSampleCount = Int(chunkDuration * rate)
        boundarySearchSampleCount = min(Int(1.5 * rate), chunkSampleCount / 2)
        silencePeakThreshold = Int(32_767 * pow(10, silenceThresholdDBFS / 20))
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: rate,
            channels: 1,
            interleaved: true
        )!
        super.init()
    }

    // MARK: Permission

    func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: Lifecycle

    @MainActor
    func start(onEvent: @escaping @Sendable (CaptureEvent) -> Void) async throws -> AsyncStream<AudioChunk> {
        guard captureStream == nil else { throw AudioCaptureError.alreadyRunning }
        guard hasScreenCapturePermission() else { throw AudioCaptureError.permissionDenied }

        let display: SCDisplay
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let firstDisplay = content.displays.first else { throw AudioCaptureError.noDisplayAvailable }
            display = firstDisplay
        } catch let error as AudioCaptureError {
            throw error
        } catch {
            throw AudioCaptureError.captureFailed(error.localizedDescription)
        }

        let directory = Self.temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AudioCaptureError.captureFailed(error.localizedDescription)
        }

        let (chunks, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        let newSession = Session(directory: directory, continuation: continuation, onEvent: onEvent)
        audioQueue.sync { self.session = newSession }

        // The whole display is the capture target, but only its audio is used. Audio from every
        // app is included except LectureMind itself, which avoids feedback loops.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let newStream = SCStream(filter: filter, configuration: Self.makeConfiguration(), delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            // SCStream always produces video. Consuming it (and dropping it) keeps ScreenCaptureKit
            // from logging a dropped-frame error for every frame.
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            try await newStream.startCapture()
        } catch {
            await finishSession()
            throw AudioCaptureError.captureFailed(error.localizedDescription)
        }
        captureStream = newStream
        logger.info("System audio capture started")
        return chunks
    }

    @MainActor
    func stop() async {
        if let activeStream = captureStream {
            captureStream = nil
            do {
                try await activeStream.stopCapture()
            } catch {
                // Expected when the system already stopped the stream (see `didStopWithError`).
                logger.notice("stopCapture: \(error.localizedDescription, privacy: .public)")
            }
        }
        await finishSession()
        logger.info("System audio capture stopped")
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: Self.temporaryRoot)
    }

    private static func makeConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Video can't be disabled, so make it as cheap as possible: 2x2 pixels at 1 fps.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        return configuration
    }

    /// Emits whatever audio is still buffered and finishes the chunk stream. It is queued
    /// behind any sample buffers already waiting on `audioQueue`, so no captured audio is lost.
    private func finishSession() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            audioQueue.async {
                if let session = self.session {
                    self.session = nil
                    if !session.pendingSamples.isEmpty {
                        self.emitChunk(session.pendingSamples, session: session)
                        session.pendingSamples.removeAll()
                    }
                    session.continuation.finish()
                }
                done.resume()
            }
        }
    }

    // MARK: Sample processing (audioQueue)

    private func process(_ sampleBuffer: CMSampleBuffer) {
        guard let session,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let input = Self.makePCMBuffer(from: sampleBuffer),
              let samples = convert(input, session: session),
              !samples.isEmpty else {
            return
        }
        reportLevel(for: samples, session: session)

        session.pendingSamples.append(contentsOf: samples)
        while session.pendingSamples.count >= chunkSampleCount {
            let split = AudioProcessing.quietestSplitIndex(
                in: session.pendingSamples,
                searchRange: (chunkSampleCount - boundarySearchSampleCount)..<chunkSampleCount,
                frameLength: AudioProcessing.targetSampleRate / 50  // 20 ms windows
            )
            let chunk = Array(session.pendingSamples[..<split])
            session.pendingSamples.removeFirst(split)
            emitChunk(chunk, session: session)
        }
    }

    /// Copies the sample buffer's audio into an `AVAudioPCMBuffer` that owns its memory, so
    /// nothing references the `CMSampleBuffer` after this returns.
    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = buffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }

    /// Resamples and downmixes to 16 kHz mono Int16. The converter is kept for the whole
    /// session so its resampling filter state carries across buffers without clicks.
    private func convert(_ input: AVAudioPCMBuffer, session: Session) -> [Int16]? {
        if session.converter?.inputFormat != input.format {
            guard let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
                logger.error("Unsupported capture format: \(input.format.description, privacy: .public)")
                return nil
            }
            converter.downmix = true
            session.converter = converter
        }
        guard let converter = session.converter else { return nil }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        let feed = SingleBufferFeed(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let buffer = feed.take() else {
                // `.noDataNow` (not `.endOfStream`) keeps the converter primed for the next buffer.
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channelData = output.int16ChannelData else {
            logger.error("Audio conversion failed: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(output.frameLength)))
    }

    private func reportLevel(for samples: [Int16], session: Session) {
        session.levelPeak = max(session.levelPeak, AudioProcessing.normalizedLevel(of: samples))
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= session.lastLevelReport + 100_000_000 else { return }
        session.onEvent(.level(session.levelPeak))
        session.levelPeak = 0
        session.lastLevelReport = now
    }

    private func emitChunk(_ samples: [Int16], session: Session) {
        let rate = Double(AudioProcessing.targetSampleRate)
        let startSample = session.processedSampleCount
        session.processedSampleCount += samples.count

        guard samples.count >= minimumChunkSampleCount else { return }
        guard AudioProcessing.peakAmplitude(of: samples) >= silencePeakThreshold else {
            logger.debug("Skipping silent chunk at sample \(startSample)")
            return
        }

        let index = session.nextChunkIndex
        session.nextChunkIndex += 1
        let url = session.directory.appendingPathComponent(String(format: "chunk-%05ld.wav", index))
        do {
            try AudioProcessing.wavData(samples: samples, sampleRate: AudioProcessing.targetSampleRate)
                .write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to write chunk: \(error.localizedDescription, privacy: .public)")
            session.onEvent(.warning("Could not save a recorded segment: \(error.localizedDescription)"))
            return
        }
        session.continuation.yield(AudioChunk(
            index: index,
            fileURL: url,
            startTime: Double(startSample) / rate,
            duration: Double(samples.count) / rate
        ))
    }

    /// Per-recording state, confined to `audioQueue`.
    private final class Session {
        let directory: URL
        let continuation: AsyncStream<AudioChunk>.Continuation
        let onEvent: @Sendable (CaptureEvent) -> Void
        var converter: AVAudioConverter?
        var pendingSamples: [Int16] = []
        /// Samples already emitted or discarded; the timeline position of `pendingSamples[0]`.
        var processedSampleCount = 0
        var nextChunkIndex = 0
        var levelPeak: Float = 0
        var lastLevelReport: UInt64 = 0

        init(directory: URL,
             continuation: AsyncStream<AudioChunk>.Continuation,
             onEvent: @escaping @Sendable (CaptureEvent) -> Void) {
            self.directory = directory
            self.continuation = continuation
            self.onEvent = onEvent
        }
    }

    /// Hands a single buffer to `AVAudioConverter`'s pull-style input block exactly once.
    private final class SingleBufferFeed {
        private var buffer: AVAudioPCMBuffer?

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }
}

// MARK: - ScreenCaptureKit callbacks

extension AudioCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Video frames are requested only to keep ScreenCaptureKit quiet; drop them.
        guard type == .audio else { return }
        process(sampleBuffer)
    }
}

extension AudioCaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Capture stopped by the system: \(error.localizedDescription, privacy: .public)")
        let message = error.localizedDescription
        audioQueue.async {
            self.session?.onEvent(.stoppedUnexpectedly(message))
        }
    }
}
