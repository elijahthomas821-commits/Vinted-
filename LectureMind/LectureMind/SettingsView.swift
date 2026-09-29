import SwiftUI

/// API keys, model choices, and permission status, shown in place of the main popover content.
@MainActor
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    var onDone: () -> Void

    @AppStorage(SettingsKeys.claudeModel) private var claudeModel = AnthropicNoteGeneratorService.defaultModel
    @AppStorage(SettingsKeys.transcriptionLanguage) private var transcriptionLanguage = ""

    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var feedback: Feedback?
    @State private var hasScreenCapturePermission = false

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
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 4)

            Form {
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
                    Text("API Keys")
                } footer: {
                    Text("Keys are stored in your macOS Keychain. Whisper (OpenAI) transcribes the audio; Claude (Anthropic) writes the notes.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Claude model", text: $claudeModel, prompt: Text(AnthropicNoteGeneratorService.defaultModel))
                    TextField("Lecture language", text: $transcriptionLanguage, prompt: Text("Auto-detect"))
                } header: {
                    Text("Models")
                } footer: {
                    Text("Language is an optional ISO-639-1 code such as “en” or “de”; setting it improves accuracy.")
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
    }

    private func load() {
        openAIKey = appState.apiKey(for: .openAI) ?? ""
        anthropicKey = appState.apiKey(for: .anthropic) ?? ""
        hasScreenCapturePermission = appState.hasScreenCapturePermission()
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
