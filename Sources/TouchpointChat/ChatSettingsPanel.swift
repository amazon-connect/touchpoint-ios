import SwiftUI
import TouchpointCore

/// How much of the screen the chat takes. Web's `WindowSize` (`interface.ts:37`), narrowed to what
/// a phone can show:
/// - `full` covers the screen — web's phone layout for `half` and `full` alike.
/// - `half` docks to the bottom half, so the app stays in view above it.
/// - `mini` is a floating panel over the app, which stays usable — web's `floating`. From 768pt
///   wide it is web's tall card (420 wide, nearly full height); on a phone a compact card instead
///   (web's covers a phone's whole screen, which is not mini at all). In a call, the voice rail is
///   the mini widget, as web's `voiceMini` is.
public enum TouchpointChatWindowMode: String, CaseIterable, Sendable {
    case full, half, mini

    var label: String {
        switch self {
        case .full: TouchpointStrings.settingsModeFull
        case .half: TouchpointStrings.settingsModeHalf
        case .mini: TouchpointStrings.settingsModeMini
        }
    }
}

/// Web's settings panel (`Settings.tsx`): restart, download the transcript, end the conversation
/// after web's confirmation (`EndConversationConfirm`, drawn by the view over the panel), as subtle
/// text buttons in a centred column. Plus the window size, when the host offers it — an iOS
/// addition: web keeps window size in host configuration.
@MainActor
struct ChatSettingsPanel: View {
    @Environment(\.touchpointTheme) private var theme
    let model: ChatTranscriptModel
    let metrics: TranscriptMetrics
    let actions: TouchpointChatActions
    let onDone: () -> Void
    /// The server's transcript (CV-1). `nil`, or nothing back: the local copy is shared instead.
    var serverTranscript: (() async -> [TranscriptEntry]?)?
    /// "End conversation" was tapped: the view shows web's confirmation over the panel and ends
    /// the conversation if the customer confirms.
    var onRequestEnd: () -> Void = {}
    @State private var serverText: String?
    @State private var busy = false

    /// Web disables restart while a person is handling a live chat (`Settings.tsx:46-54`).
    private var canRestart: Bool { !(model.escalated && !model.isEnded) }

    var body: some View {
        // Centred when it fits, as web's column is; scrolls when it does not — the mini window is
        // shorter than the full set of rows.
        ViewThatFits(in: .vertical) {
            column.frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView { column }.scrollBounceBehavior(.basedOnSize)
        }
        .task {
            guard let serverTranscript, let entries = await serverTranscript(), !entries.isEmpty else { return }
            serverText = Self.transcript(entries: entries)
        }
    }

    private var column: some View {
        VStack(spacing: metrics.controlPadding) {
            if let onRestart = actions.onRestart {
                row(TouchpointStrings.settingsRestartLabel, icon: .restart, enabled: canRestart && !busy) {
                    run { await onRestart() }
                }
            }
            // Fetched as the panel opens, so the share sheet has it the moment it is tapped.
            ShareLink(item: serverText ?? Self.transcript(model.messages), subject: Text(TouchpointStrings.transcriptTitle)) {
                Text(TouchpointStrings.settingsDownloadLabel)
            }
            .buttonStyle(TouchpointTextButtonStyle(.subtle, icon: .download))
            if actions.onEndConversation != nil {
                row(TouchpointStrings.settingsEndLabel, icon: .logOut,
                    enabled: !model.isEnded && !busy) { onRequestEnd() }
            }
            ForEach(Array(actions.settingsRows.enumerated()), id: \.offset) { _, row in
                Button {
                    // Closed first and synchronously: the row's action usually opens something
                    // else (a call), which should not sit under the panel.
                    onDone()
                    row.action()
                } label: { Text(row.label) }   // the host's own words, shown as given
                .buttonStyle(TouchpointTextButtonStyle(row.isProminent ? .main : .subtle, icon: nil))
                .disabled(busy)
            }
            if let mode = actions.windowMode, let change = actions.onWindowModeChange {
                VStack(alignment: .leading, spacing: metrics.controlGap) {
                    Text(TouchpointStrings.settingsWindowModeLabel)
                        .font(metrics.smallFont)
                        .foregroundStyle(theme.primary(.t60))
                    Picker(TouchpointStrings.settingsWindowModeLabel, selection: Binding(get: { mode }, set: { change($0) })) {
                        ForEach(TouchpointChatWindowMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.top, metrics.controlPadding)
            }
        }
        .frame(maxWidth: metrics.settingsMaxWidth)
        // Web's settings column is `p-2` on a phone (`Settings.tsx:44`).
        .padding(metrics.controlPadding)
        .frame(maxWidth: .infinity)
    }

    /// Runs a hook once, then leaves the panel for the conversation it changed.
    private func run(_ work: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            await work()
            busy = false
            onDone()
        }
    }

    /// Web's subtle `TextButton`: label leading, icon trailing, primary-10 fill.
    private func row(_ title: String, icon: TouchpointIcon, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title) }
            .buttonStyle(TouchpointTextButtonStyle(.subtle, icon: icon))
            .disabled(!enabled)
    }

    /// Web's file (`App.tsx:64-85`): one `[time] name: words` line per message, from the server.
    nonisolated static func transcript(entries: [TranscriptEntry]) -> String {
        entries.map { "[\($0.absoluteTime)] \($0.name): \($0.text)" }.joined(separator: "\n")
    }

    /// The local fallback, offline: one message per paragraph with its sender. Attachments are
    /// left out: their bytes are not in the text, and a bare file name reads as something said.
    static func transcript(_ messages: [Message]) -> String {
        messages
            .filter { TranscriptLayout.isRenderable($0) && $0.attachment == nil }
            .map { "\(ChatTranscriptModel.senderName($0)): \($0.body)" }
            .joined(separator: "\n\n")
    }
}
