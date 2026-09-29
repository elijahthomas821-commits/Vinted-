# LectureMind

A macOS menu bar app that records whatever your Mac is playing (an online lecture, a recorded
class, a webinar), transcribes it with OpenAI Whisper while you listen, and turns the transcript
into structured Markdown notes with Anthropic Claude.

- **System audio capture** with ScreenCaptureKit. No virtual audio cables or drivers, and
  LectureMind's own audio is excluded.
- **Live transcript**: audio is cut into ~30 s, 16 kHz mono WAV chunks at natural pauses and
  transcribed while you record. Failed chunks are retried when you stop.
- **Structured notes** (title, executive summary, key concepts, detailed breakdown, action items
  and dates), streamed into the popover as Claude writes them.
- **Copy / export** the notes or transcript as Markdown. Every session is also auto-saved to
  `~/Library/Application Support/LectureMind/Sessions/`.
- API keys are stored in the macOS Keychain.

## Requirements

- macOS 14 Sonoma or later
- Xcode 15.4 or later
- An OpenAI API key (Whisper transcription) and an Anthropic API key (note generation)

## Build & run

```sh
cd LectureMind
xcodebuild -scheme LectureMind -configuration Debug build
xcodebuild -scheme LectureMind -configuration Debug -destination 'platform=macOS' test
```

Or open `LectureMind.xcodeproj` in Xcode and press ⌘R. The project signs ad hoc ("Sign to Run
Locally"). To distribute it, pick your team under *Signing & Capabilities*.

On first launch:

1. Click the brain icon in the menu bar, then the gear, and save both API keys.
2. Press **Start Recording**. macOS asks for *Screen & System Audio Recording* permission. Allow
   it in System Settings › Privacy & Security, then quit and relaunch LectureMind. macOS only
   applies the permission after a relaunch.
3. Play your lecture. The transcript fills in about every 30 seconds.
4. Press **Stop & Generate Notes**. When the notes are ready, use **Copy Notes** or **Export .md**.

> Debug builds are signed ad hoc, so every rebuild looks like a new app to macOS. You may be
> asked for the recording permission and Keychain access again after rebuilding.

## Settings

| Setting | Default | Notes |
| --- | --- | --- |
| Claude model | `claude-opus-5-5` | Any Messages API model ID. |
| Lecture language | Auto-detect | ISO-639-1 code (`en`, `de`, …). Setting it improves Whisper's accuracy. |

## Architecture

| File | Responsibility |
| --- | --- |
| `LectureMindApp.swift` | `MenuBarExtra` entry point (window style, no Dock icon via `LSUIElement`). |
| `AppState.swift` | `@MainActor` state machine: `idle → recording → transcribing → generatingNotes → completed / error`. Runs the chunk pipeline in order, retries failed chunks, streams notes, autosaves. |
| `AudioCaptureManager.swift` | `SCStream` audio capture → `AVAudioConverter` (48 kHz stereo float → 16 kHz mono Int16) → WAV chunks emitted on an `AsyncStream<AudioChunk>`. Skips silent chunks, which Whisper tends to hallucinate on. |
| `AudioProcessing.swift` | Pure helpers: WAV encoding, level metering, choosing a quiet split point. |
| `TranscriptionService.swift` | `TranscriptionServiceProtocol`, the OpenAI Whisper client (`whisper-1`), a `LocalWhisperKitTranscriptionService` stub, and `FallbackTranscriptionService` for chaining engines. |
| `NoteGeneratorService.swift` | System prompt and a streaming Anthropic Messages API client with an SSE parser. |
| `APIClientSupport.swift` | Shared `APIError`, retry with backoff (honors `retry-after`), multipart builder. |
| `KeychainStore.swift` | API key storage in the login Keychain. |
| `SessionArchive.swift` | Auto-saves each session's transcript and notes. |
| `MenuView.swift`, `MarkdownNotesView.swift`, `SettingsView.swift` | Popover UI, Markdown rendering, and the settings panel. |

### Offline transcription (WhisperKit)

`LocalWhisperKitTranscriptionService` is a stub that throws `localEngineUnavailable`. To go
offline, add the [WhisperKit](https://github.com/argmaxinc/WhisperKit) package, implement the stub
(the chunks are already 16 kHz mono WAV, WhisperKit's native format), and pass it to `AppState`'s
`makeTranscriber`, alone or wrapped in `FallbackTranscriptionService`.

### Microphone

`NSMicrophoneUsageDescription` is declared, but the app records system audio only. To add the
user's own voice, capture it separately (for example with `SCStreamConfiguration.captureMicrophone`
on macOS 15) and mix it into the chunk buffer in `AudioCaptureManager`.
