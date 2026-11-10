import Foundation
import SwiftUI
import TouchpointCore
import UniformTypeIdentifiers

// Attachments (gap index AT-1…7), after web's `Input.tsx:63-300` and
// `Messages.tsx:194-215`. The vendor chat SDK uploads and signs downloads; this file is the rules
// and views around it.

/// What the composer accepts: web's list and 8 MB cap (`Input.tsx:40, 290`).
///
/// **Deviation:** web also offers `.webp` and `.avi`. The Connect chat SDK refuses both (they are
/// not in its `AttachmentTypes`, which mirrors Connect's own list), so they are not offered rather
/// than offered and then failed.
enum AttachmentPolicy {
    static let maxMegabytes = 8
    static let maxBytes = maxMegabytes * 1024 * 1024
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "mp4", "mov", "pdf"]
    /// For the system picker. `.jpeg` covers `.jpg`.
    static let contentTypes: [UTType] = [.jpeg, .png, .mpeg4Movie, .quickTimeMovie, .pdf]

    enum Verdict: Equatable { case accepted, tooBig, unsupportedType }

    static func validate(fileName: String, size: Int) -> Verdict {
        guard extensions.contains((fileName as NSString).pathExtension.lowercased()) else { return .unsupportedType }
        return size > maxBytes ? .tooBig : .accepted
    }
}

/// The composer's upload, as web's `attachmentState` plus `uploadedFileInfo` and the error line.
enum AttachmentUpload: Equatable {
    case idle
    case uploading(name: String)
    case failed(name: String?, message: String)

    var isUploading: Bool { if case .uploading = self { true } else { false } }
}

/// The picked file, prepared for the vendor SDK: validated, then copied out of the picker's
/// security scope into a directory this app owns, because the SDK reads it after returning.
enum AttachmentFiles {
    enum PrepareError: Error, Equatable { case tooBig, unsupportedType, unreadable }

    static func prepare(_ picked: URL) throws -> URL {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        guard let size = try? picked.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw PrepareError.unreadable }
        switch AttachmentPolicy.validate(fileName: picked.lastPathComponent, size: size) {
        case .tooBig: throw PrepareError.tooBig
        case .unsupportedType: throw PrepareError.unsupportedType
        case .accepted: break
        }
        let dir = try scratchDirectory()
        let copy = dir.appendingPathComponent(picked.lastPathComponent)
        do { try FileManager.default.copyItem(at: picked, to: copy) } catch { throw PrepareError.unreadable }
        return copy
    }

    /// Downloads an attachment from its signed link into a fresh scratch directory, under its own
    /// name reduced to a single path component.
    static func download(_ remote: URL, name: String) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: remote)
        // Connect's link is a signed HTTPS URL; a host's own transport may hand back a local file.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let safe = URL(fileURLWithPath: name).lastPathComponent
        let local = try scratchDirectory().appendingPathComponent(safe.isEmpty || safe == "/" ? "attachment" : safe)
        try FileManager.default.moveItem(at: temp, to: local)
        return local
    }

    /// Removes a file `prepare` or `download` made, with its directory.
    static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private static func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchpointAttachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// How a transcript attachment opens: set by the transcript, read by each pill.
struct AttachmentActions {
    var open: (@MainActor (MessageAttachment) -> Void)?
}

extension EnvironmentValues {
    @Entry var touchpointAttachmentActions = AttachmentActions()
}

/// Web's `AttachmentPill`: the paperclip and the name in a quiet `primary5` well, inner radius,
/// 12 × 8 padding. The customer's own is not pressable (web passes no `onClick`); the agent's opens.
@MainActor
struct AttachmentPill: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.touchpointAttachmentActions) private var actions
    let attachment: MessageAttachment
    let metrics: TranscriptMetrics
    let opens: Bool

    var body: some View {
        let open = opens ? actions.open : nil
        Button { open?(attachment) } label: {
            HStack(spacing: metrics.controlPadding) {
                TouchpointIconView(.attachment, size: metrics.iconGlyphSize)
                Text(attachment.name)
                    .font(metrics.bodyFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(theme.primary(.t90))
            .padding(.horizontal, metrics.controlPaddingWide)
            .padding(.vertical, metrics.controlPadding)
            .background(theme.primary(.t5), in: TouchpointShape.rounded(metrics.innerRadius))
            .contentShape(TouchpointShape.rounded(metrics.innerRadius))
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
        .accessibilityLabel(TouchpointStrings.attachmentLabel(attachment.name))
        // A file of one's own is information, not a control.
        .accessibilityRemoveTraits(open == nil ? .isButton : [])
    }
}

/// Web's chip above the field (`Input.tsx:238-271`): a pulsing dot while uploading, the error glyph
/// after a failure, then the name and Delete; the error line sits above it with `role="alert"`.
@MainActor
struct ComposerAttachmentStatus: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let upload: AttachmentUpload
    let metrics: TranscriptMetrics
    let onDelete: () -> Void
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: metrics.controlPadding) {
            if case .failed(_, let message) = upload {
                HStack(spacing: metrics.controlGap) {
                    TouchpointIconView(.error, size: metrics.iconGlyphSize)
                    Text(message).font(metrics.bodyFont).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.primary(.t80))
                .padding(.horizontal, metrics.controlPadding)
                .padding(.vertical, metrics.controlGap)
                .background(theme.errorSecondary, in: TouchpointShape.rounded(metrics.innerRadius))
                .accessibilityElement(children: .combine)
            }
            if let name {
                HStack(spacing: metrics.controlPaddingWide) {
                    leading.frame(width: metrics.attachmentStatusSize, height: metrics.attachmentStatusSize)
                    Text(name)
                        .font(metrics.bodyFont)
                        .foregroundStyle(theme.primary(.t90))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityValue(upload.isUploading ? TouchpointStrings.attachmentUploading : "")
                    Spacer(minLength: 0)
                    Button(action: onDelete) { TouchpointIconView(.delete) }
                        .buttonStyle(TouchpointIconButtonStyle(.ghost))
                        .accessibilityLabel(TouchpointStrings.attachmentDeleteLabel)
                }
                .padding(.leading, metrics.controlPadding)
            }
            Rectangle()
                .fill(theme.background)
                .frame(height: metrics.hairline)
                .padding(.horizontal, -metrics.composerShellPadding)
                .accessibilityHidden(true)
        }
    }

    private var name: String? {
        switch upload {
        case .idle: nil
        case .uploading(let name): name
        case .failed(let name, _): name
        }
    }

    @ViewBuilder
    private var leading: some View {
        if upload.isUploading {
            // Web's `animate-upload-pulse`: scale 1 → 1.5 → 1 over a second. Held still under
            // Reduce Motion.
            Circle()
                .fill(theme.primary(.t60))
                .frame(width: metrics.attachmentPulseDot, height: metrics.attachmentPulseDot)
                .scaleEffect(pulsing && !reduceMotion ? 1.5 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
                .accessibilityHidden(true)
        } else {
            TouchpointIconView(.error, size: metrics.iconGlyphSize)
                .foregroundStyle(theme.error)
        }
    }
}
