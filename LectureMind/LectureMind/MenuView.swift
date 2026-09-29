import AppKit
import SwiftUI

/// The popover shown from the menu bar icon.
@MainActor
struct MenuView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: AppState.PreviewContent = .transcript
    @State private var isShowingSettings = false
    @State private var didCopy = false

    var body: some View {
        Group {
            if isShowingSettings {
                SettingsView(onDone: { isShowingSettings = false })
            } else {
                mainContent
            }
        }
        .frame(width: 440, height: 600)
        .onChange(of: appState.status) {
            switch appState.status {
            case .recording: selectedTab = .transcript
            case .generatingNotes, .completed: selectedTab = .notes
            default: break
            }
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            StatusCard()
            primaryButton
            banners
            Picker("Preview", selection: $selectedTab) {
                Text("Transcript").tag(AppState.PreviewContent.transcript)
                Text("Notes").tag(AppState.PreviewContent.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            previewPane
            footer
        }
        .padding(16)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("LectureMind")
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    private var primaryButton: some View {
        Button {
            Task { await appState.toggleRecording() }
        } label: {
            Label(
                appState.isRecording ? "Stop & Generate Notes" : "Start Recording",
                systemImage: appState.isRecording ? "stop.circle.fill" : "record.circle"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(appState.isRecording ? .red : .accentColor)
        .disabled(!(appState.isRecording || appState.canStartRecording))
    }

    @ViewBuilder
    private var banners: some View {
        if case .error(let message) = appState.status {
            Banner(systemImage: "exclamationmark.octagon.fill", tint: .red, message: message) {
                if appState.needsScreenCapturePermission {
                    Button("Open Privacy Settings") { SystemSettings.openScreenRecordingPrivacy() }
                }
                if message.localizedCaseInsensitiveContains("API key") {
                    Button("Open Settings") { isShowingSettings = true }
                }
                if appState.canRegenerateNotes {
                    Button("Regenerate Notes") { Task { await appState.regenerateNotes() } }
                }
            }
        }
        if let warning = appState.warning {
            Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange, message: warning) {
                EmptyView()
            }
        }
    }

    private var previewPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    previewContent
                        .padding(12)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
            }
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .onChange(of: appState.transcript) {
                // Follow the live transcript while recording.
                if selectedTab == .transcript && appState.isRecording {
                    withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch selectedTab {
        case .transcript:
            if appState.transcript.isEmpty {
                placeholder(appState.isRecording
                    ? "Listening… the first transcript segment appears about 30 seconds after recording starts."
                    : "The live transcript will appear here while you record.")
            } else {
                Text(appState.transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .notes:
            if appState.notes.isEmpty {
                placeholder(appState.status == .generatingNotes
                    ? "Claude is reading the transcript…"
                    : "Structured notes appear here after you stop recording.")
            } else {
                MarkdownNotesView(markdown: appState.notes)
            }
        }
    }

    private var footer: some View {
        let hasContent = !appState.text(for: selectedTab).isEmpty
        let noun = selectedTab == .notes ? "Notes" : "Transcript"
        let copyTitle = didCopy ? "Copied" : "Copy \(noun)"
        return HStack(spacing: 8) {
            Button {
                if appState.copyToClipboard(selectedTab) {
                    didCopy = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        didCopy = false
                    }
                }
            } label: {
                Label(copyTitle, systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .disabled(!hasContent)
            .help("Copy the \(noun.lowercased()) to the clipboard")

            Button {
                appState.export(selectedTab)
            } label: {
                Label("Export .md", systemImage: "square.and.arrow.up")
            }
            .disabled(!hasContent)
            .help("Save the \(noun.lowercased()) as a Markdown file")

            Spacer()

            if appState.canRegenerateNotes {
                Button {
                    Task { await appState.regenerateNotes() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Regenerate notes from the transcript")
            }

            Button {
                appState.revealArchive()
            } label: {
                Image(systemName: "folder")
            }
            .help("Show auto-saved transcripts and notes in Finder")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit LectureMind")
        }
        .controlSize(.regular)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let bottomAnchor = "preview-bottom"
}

// MARK: - Status

/// Status indicator, description, and session timer.
@MainActor
private struct StatusCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            indicator
                .frame(width: 96, height: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.status.title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            ElapsedTimeView(start: appState.recordingStartedAt, end: appState.recordingEndedAt)
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var indicator: some View {
        switch appState.status {
        case .idle:
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.secondary)
        case .recording:
            LevelMeterView(model: appState.levelMeter)
        case .transcribing, .generatingNotes:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        }
    }

    private var detail: String {
        switch appState.status {
        case .idle:
            return "Play your lecture, then start recording."
        case .recording:
            return appState.pendingChunkCount > 0
                ? "Capturing system audio · transcribing a segment…"
                : "Capturing system audio · transcribed every 30 s"
        case .transcribing:
            return "Transcribing the last segments…"
        case .generatingNotes:
            return "Claude is structuring your notes…"
        case .completed:
            return "Copy or export your notes below."
        case .error:
            return "See details below."
        }
    }
}

/// Live input level as a scrolling bar graph.
private struct LevelMeterView: View {
    @ObservedObject var model: LevelMeterModel

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(model.levels.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.red.gradient)
                    .frame(width: 2, height: max(2, CGFloat(model.levels[index]) * 26))
            }
        }
        .frame(height: 28)
        .animation(.linear(duration: 0.1), value: model.levels)
        .accessibilityLabel("Audio level")
    }
}

private struct ElapsedTimeView: View {
    let start: Date?
    let end: Date?

    var body: some View {
        if let start {
            Group {
                if let end {
                    Text(TimeFormatting.clock(end.timeIntervalSince(start)))
                } else {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(TimeFormatting.clock(context.date.timeIntervalSince(start)))
                    }
                }
            }
            .font(.system(.title3, design: .rounded).weight(.medium))
            .monospacedDigit()
            .accessibilityLabel("Elapsed time")
        }
    }
}

private struct Banner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
            HStack(spacing: 8) {
                actions()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Presentation helpers

extension AppState.Status {
    var title: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .generatingNotes: return "Generating Notes"
        case .completed: return "Notes Ready"
        case .error: return "Needs Attention"
        }
    }

    var menuBarSymbolName: String {
        switch self {
        case .idle: return "brain.head.profile"
        case .recording: return "record.circle.fill"
        case .transcribing, .generatingNotes: return "ellipsis.circle"
        case .completed: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }
}

enum SystemSettings {
    static func openScreenRecordingPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
