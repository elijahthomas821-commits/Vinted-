import SwiftUI

/// Engines, API keys, model choices, and permission status, shown in place of the main popover content.
@MainActor
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    var onDone: () -> Void

    @AppStorage(SettingsKeys.transcriptionEngine) private var transcriptionEngine: TranscriptionEngine = .appleOnDevice
    @AppStorage(SettingsKeys.noteEngine) private var noteEngine: NoteEngine = .appleIntelligence
    @AppStorage(SettingsKeys.claudeModel) private var claudeModel = AnthropicNoteGeneratorService.defaultModel
    @AppStorage(SettingsKeys.transcriptionLanguage) private var transcriptionLanguage = ""

    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var feedback: Feedback?
    @State private var hasScreenCapturePermission = false
    @State private var appleIntelligenceProblem: String?

    private struct Feedback {
        let message: String
        let isError: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") {
                    appState.settingsDidChange()
                    onDone()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 4)

            Form {
                Section {
                    Picker("Transcription", selection: $transcriptionEngine) {
                        ForEach(TranscriptionEngine.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Notes", selection: $noteEngine) {
                        ForEach(NoteEngine.allCases) { Text($0.displayName).tag($0) }
                    }
                    if noteEngine == .appleIntelligence {
                        Label(
                            appleIntelligenceProblem.map { "Unavailable: \($0)" } ?? "Apple Intelligence is ready on this Mac.",
                            systemImage: appleIntelligenceProblem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(appleIntelligenceProblem == nil ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Engines")
                } footer: {
                    Text("The free engines run on your Mac and need no account. Apple Intelligence notes need macOS 26 on an Apple Silicon Mac with Apple Intelligence turned on.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    SecureField("OpenAI", text: $openAIKey, prompt: Text("sk-…"))
                    SecureField("Anthropic", text: $anthropicKey, prompt: Text("sk-ant-…"))
                    HStack {
                        if let feedback {
                            Label(feedback.message, systemImage: feedback.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                                .foregroundStyle(feedback.isError ? Color.red : Color.green)
                                .font(.callout)
                        }
                        Spacer()
                        Button("Save Keys", action: saveKeys)
                            .keyboardShortcut(.defaultAction)
                    }
                } header: {
                    Text("API Keys (optional)")
                } footer: {
                    Text("Only needed for the paid engines: OpenAI for Whisper transcription, Anthropic for Claude notes. Keys are stored in your macOS Keychain and billed by those providers.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Lecture language", text: $transcriptionLanguage, prompt: Text("Auto-detect"))
                    if noteEngine == .claude {
                        TextField("Claude model", text: $claudeModel, prompt: Text(AnthropicNoteGeneratorService.defaultModel))
                    }
                } header: {
                    Text("Language & Models")
                } footer: {
                    Text("Language is an optional code such as “en”, “en-GB” or “de”; setting it improves accuracy.")
                        .foregroundStyle(.secondary)
                }

                Section("Permissions") {
                    HStack {
                        Label(
                            hasScreenCapturePermission ? "Screen & System Audio Recording allowed" : "Screen & System Audio Recording not allowed",
                            systemImage: hasScreenCapturePermission ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                        )
                        .foregroundStyle(hasScreenCapturePermission ? Color.green : Color.orange)
                        Spacer()
                        Button("Open…") { SystemSettings.openScreenRecordingPrivacy() }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear(perform: load)
        .onChange(of: noteEngine) {
            appleIntelligenceProblem = appState.appleIntelligenceStatus()
            appState.settingsDidChange()
        }
    }

    private func load() {
        openAIKey = appState.apiKey(for: .openAI) ?? ""
        anthropicKey = appState.apiKey(for: .anthropic) ?? ""
        hasScreenCapturePermission = appState.hasScreenCapturePermission()
        appleIntelligenceProblem = appState.appleIntelligenceStatus()
        feedback = nil
    }

    private func saveKeys() {
        do {
            try appState.setAPIKey(openAIKey, for: .openAI)
            try appState.setAPIKey(anthropicKey, for: .anthropic)
            feedback = Feedback(message: "Saved", isError: false)
        } catch {
            feedback = Feedback(message: error.localizedDescription, isError: true)
        }
    }
}
