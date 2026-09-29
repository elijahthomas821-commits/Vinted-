# LectureMind

A macOS menu bar app that records whatever your Mac is playing (an online lecture, a recorded
class, a webinar), transcribes it while you listen, and turns the transcript into structured
Markdown notes.

**It's free by default.** Transcription uses Apple's on-device speech recognition and the notes are
written by the on-device Apple Intelligence model, so no account or API key is needed and the audio
never leaves your Mac. OpenAI Whisper and Anthropic Claude are available as optional paid engines
in Settings.

- **System audio capture** with ScreenCaptureKit. No virtual audio cables or drivers, and
  LectureMind's own audio is excluded.
- **Live transcript**: audio is cut into ~30 s, 16 kHz mono WAV chunks at natural pauses and
  transcribed while you record. Failed chunks are retried when you stop.
- **Structured notes** (title, executive summary, key concepts, detailed breakdown, action items
  and dates). Apple Intelligence summarizes long lectures piece by piece; Claude streams the notes
  in as it writes them.
- **Copy / export** the notes or transcript as Markdown. Every session is also auto-saved to
  `~/Library/Application Support/LectureMind/Sessions/`.
- API keys for the optional paid engines are stored in the macOS Keychain.

## Requirements

- macOS 14 Sonoma or later, on Apple Silicon or Intel
- For the free notes engine: macOS 26 on an Apple Silicon Mac with Apple Intelligence turned on.
  On other Macs, choose Claude for notes (needs an Anthropic API key).
- Optional: an OpenAI API key (Whisper transcription) and/or an Anthropic API key (Claude notes)
- Xcode 15.4 or later to build from source; Xcode 26 or later to include the free on-device notes engine

## Download

**[Download LectureMind.zip](https://github.com/elijahthomas821-commits/Vinted-/releases/download/lecturemind-latest/LectureMind.zip)**
is the latest build of `main`. CI rebuilds it after every change that passes the tests.

1. Unzip it and drag `LectureMind.app` into Applications.
2. Open it. The app isn't signed with an Apple Developer ID, so macOS says it can't verify the
   developer. Go to **System Settings › Privacy & Security**, scroll down, and click
   **Open Anyway**. Alternatively, run `xattr -dr com.apple.quarantine /Applications/LectureMind.app`.
3. Continue with the first-launch steps below.

## Build & run

```sh
cd LectureMind
xcodebuild -scheme LectureMind -configuration Debug build
xcodebuild -scheme LectureMind -configuration Debug -destination 'platform=macOS' test
```

Or open `LectureMind.xcodeproj` in Xcode and press ⌘R. The project signs ad hoc ("Sign to Run
Locally"). To distribute it, pick your team under *Signing & Capabilities*.

On first launch:

1. Click the brain icon in the menu bar. The free engines are selected by default; open the gear
   only if you want the paid engines or a specific lecture language.
2. Press **Start Recording**. macOS asks for *Screen & System Audio Recording* permission. Allow
   it in System Settings › Privacy & Security, then quit and relaunch LectureMind. macOS only
   applies the permission after a relaunch. The first recording may also download Apple's
   on-device speech model, or ask for *Speech Recognition* permission on older macOS versions.
3. Play your lecture. The transcript fills in about every 30 seconds.
4. Press **Stop & Generate Notes**. When the notes are ready, use **Copy Notes** or **Export .md**.

> Debug builds are signed ad hoc, so every rebuild looks like a new app to macOS. You may be
> asked for the recording permission and Keychain access again after rebuilding.

## Settings

| Setting | Default | Notes |
| --- | --- | --- |
| Transcription | Apple on-device (free) | Or OpenAI Whisper (paid, needs an OpenAI key). |
| Notes | Apple Intelligence (free) | Or Claude (paid, needs an Anthropic key). |
| Lecture language | Auto-detect (your Mac's language for Apple speech) | Language code such as `en`, `en-GB` or `de`. Setting it improves accuracy. |
| Claude model | `claude-opus-5-5` | Any Messages API model ID; only used when notes use Claude. |

## Architecture

| File | Responsibility |
| --- | --- |
| `LectureMindApp.swift` | `MenuBarExtra` entry point (window style, no Dock icon via `LSUIElement`). |
| `AppState.swift` | `@MainActor` state machine: `idle → recording → transcribing → generatingNotes → completed / error`. Runs the chunk pipeline in order, retries failed chunks, streams notes, autosaves. |
| `AudioCaptureManager.swift` | `SCStream` audio capture → `AVAudioConverter` (48 kHz stereo float → 16 kHz mono Int16) → WAV chunks emitted on an `AsyncStream<AudioChunk>`. Skips silent chunks, which Whisper tends to hallucinate on. |
| `AudioProcessing.swift` | Pure helpers: WAV encoding, level metering, choosing a quiet split point. |
| `TranscriptionService.swift` | `TranscriptionServiceProtocol`, the OpenAI Whisper client (`whisper-1`), a `LocalWhisperKitTranscriptionService` stub, and `FallbackTranscriptionService` for chaining engines. |
| `AppleSpeechTranscriptionService.swift` | Free transcription: `SpeechTranscriber` (macOS 26, fully on-device), falling back to `SFSpeechRecognizer`. |
| `NoteGeneratorService.swift` | System prompt and a streaming Anthropic Messages API client with an SSE parser. |
| `AppleIntelligenceNoteGenerator.swift`, `ChunkedNoteComposer.swift` | Free notes: the on-device Foundation Models LLM summarizes the transcript in chunks that fit its small context window; the composer assembles the five note sections. |
| `APIClientSupport.swift` | Shared `APIError`, retry with backoff (honors `retry-after`), multipart builder. |
| `KeychainStore.swift` | API key storage in the login Keychain. |
| `SessionArchive.swift` | Auto-saves each session's transcript and notes. |
| `MenuView.swift`, `MarkdownNotesView.swift`, `SettingsView.swift` | Popover UI, Markdown rendering, and the settings panel. |

### WhisperKit

Apple's speech recognition already provides free on-device transcription.
`LocalWhisperKitTranscriptionService` is a stub for a third option, local Whisper models. To use
it, add the [WhisperKit](https://github.com/argmaxinc/WhisperKit) package, implement the stub
(the chunks are already 16 kHz mono WAV, WhisperKit's native format), and pass it to `AppState`'s
`makeTranscriber`, alone or wrapped in `FallbackTranscriptionService`.

### Microphone

`NSMicrophoneUsageDescription` is declared, but the app records system audio only. To add the
user's own voice, capture it separately (for example with `SCStreamConfiguration.captureMicrophone`
on macOS 15) and mix it into the chunk buffer in `AudioCaptureManager`.
