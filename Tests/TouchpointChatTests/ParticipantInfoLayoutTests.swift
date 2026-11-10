import Foundation
import SwiftUI
import Testing
import TouchpointCore
@testable import TouchpointChat

/// Message rows and avatars as web draws them after 8cebb4d. Rendered
/// with `ImageRenderer` off the surface, so ink alpha is the signal.
@Suite("Participant info and message parity")
@MainActor
struct ParticipantInfoLayoutTests {
    private let metrics = TranscriptMetrics(scale: 1, theme: .default)
    private let info = TouchpointChatOptions(showParticipantInfo: true)

    private struct Ink { var minX: Int; var maxX: Int; var minY: Int; var maxY: Int; var width: Int; var height: Int }

    private func ink(_ view: some View, width: CGFloat) -> (Ink, [UInt8]) {
        let renderer = ImageRenderer(content: view.frame(width: width).environment(\.colorScheme, .light))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return (Ink(minX: 0, maxX: -1, minY: 0, maxY: -1, width: 0, height: 0), []) }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        if let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var box = Ink(minX: w, maxX: -1, minY: h, maxY: -1, width: w, height: h)
        for y in 0..<h { for x in 0..<w where bytes[(y * w + x) * 4 + 3] > 12 {
            box.minX = min(box.minX, x); box.maxX = max(box.maxX, x)
            box.minY = min(box.minY, y); box.maxY = max(box.maxY, y)
        } }
        return (box, bytes)
    }

    private func outbound(_ body: String) -> Message {
        Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s1", body: body, direction: .outbound,
                              participantRole: .customer, sequence: 1, deliveryState: .sent))
    }

    private func row(_ message: Message, options: TouchpointChatOptions, startsRun: Bool) -> some View {
        MessageRow(row: TranscriptLayout.rows(for: [message])[0], metrics: metrics, canRetry: true, feedbackGiven: nil,
                   onRetry: { _ in true }, onFeedback: nil, options: options, startsRun: startsRun, participantName: "You")
    }

    private func inbound(_ body: String) -> Message {
        Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "a1", body: body, direction: .inbound,
                              participantRole: .assistant, sequence: 1, deliveryState: .delivered))
    }

    /// The ink box of the image's rows `rows` (points, top first).
    private func band(_ bytes: [UInt8], width w: Int, rows: Range<Int>) -> (minX: Int, maxX: Int) {
        var minX = w, maxX = -1
        for y in rows { for x in 0..<w where bytes[(y * w + x) * 4 + 3] > 12 { minX = min(minX, x); maxX = max(maxX, x) } }
        return (minX, maxX)
    }

    @Test("An icon avatar is a 20pt primary-10 disc for every role (c60, c64)")
    func iconAvatar() {
        for role in [ChatOptions.AvatarRole.you, .agent, .bot] {
            // Rendered in a wider frame, so its own extent is measured rather than the frame's.
            let (box, bytes) = ink(ParticipantAvatar(role: role, metrics: metrics, options: .default), width: 40)
            #expect(box.maxX - box.minX + 1 == 20 && box.maxY - box.minY + 1 == 20, "\(role) \(box)")
            // Just inside the disc's top edge, clear of the 14pt glyph: the fill alone, 10% black.
            let alpha = Double(bytes[((box.minY + 2) * box.width + box.minX + 10) * 4 + 3]) / 255
            #expect(abs(alpha - 0.1) < 0.03, "\(role) disc alpha \(alpha)")
        }
    }

    @Test("A host's assistant image avatar is 16pt (web `size-4`)")
    func imageAvatar() {
        let options = TouchpointChatOptions(assistantIcon: Image(systemName: "square.fill"))
        let (box, _) = ink(ParticipantAvatar(role: .bot, metrics: metrics, options: options), width: 40)
        #expect(box.maxX - box.minX + 1 <= 16 && box.maxY - box.minY + 1 <= 16 && box.maxX > box.minX, "\(box)")
    }

    @Test("Under participant info the customer's message stays trailing behind the 48pt gutter (c57, c58)")
    func userRowTrailing() {
        let message = outbound("Where is my card?")
        let (withInfo, _) = ink(row(message, options: info, startsRun: false), width: 390)
        let (without, _) = ink(row(message, options: .default, startsRun: false), width: 390)
        #expect(withInfo.minX > 150, "user row starts at \(withInfo.minX) of 390: it should hug the trailing edge")
        #expect(abs(withInfo.minX - without.minX) <= 1, "participant info moved the customer's message")
        // A long message wraps short of the 48pt gutter.
        let (long, _) = ink(row(outbound(String(repeating: "word ", count: 60)), options: .default, startsRun: true), width: 390)
        #expect(long.minX >= 48, "a wrapped user message reaches \(long.minX), inside the 48pt gutter")
    }

    @Test("Only the first message of a customer run carries the avatar and You header, trailing (c59)")
    func userHeaderOncePerRun() {
        let message = outbound("Where is my card?")
        let (first, bytes) = ink(row(message, options: info, startsRun: true), width: 390)
        let (continued, _) = ink(row(message, options: info, startsRun: false), width: 390)
        #expect(first.height - continued.height >= 20, "header added \(first.height - continued.height)pt")
        // The header line alone: the top 20 rows hold the avatar and "You", hugging the trailing edge.
        let header = band(bytes, width: first.width, rows: 0..<min(20, first.height))
        #expect(header.minX > 300 && header.maxX >= 380, "header ink spans \(header)")
    }

    @Test("A bubbled agent message keeps 40pt clear on its trailing side (c57)")
    func agentBubbleMargin() {
        let options = TouchpointChatOptions(agentMessageBubble: true)
        let (box, _) = ink(row(inbound(String(repeating: "word ", count: 60)), options: options, startsRun: true), width: 390)
        #expect(box.maxX <= 390 - 40, "the agent bubble reaches \(box.maxX) of 390")
    }

    @Test("Under participant info the content starts 32pt in: a 24pt avatar column and an 8pt gap (c61)")
    func agentContentInset() {
        let (box, bytes) = ink(row(inbound(String(repeating: "word ", count: 30)), options: info, startsRun: false), width: 390)
        // A continuation row has no avatar, so its first ink is the words.
        let words = band(bytes, width: box.width, rows: 0..<box.height)
        #expect(abs(words.minX - 32) <= 2, "content starts at \(words.minX)")
    }

    @Test("The customer's status row sits 4pt in from the trailing edge (c28)")
    func statusInset() {
        let (box, bytes) = ink(row(outbound("Hi"), options: TouchpointChatOptions(userMessageBubble: false), startsRun: true), width: 390)
        // The bottom 16 rows are the status row ("Sent" and its glyph).
        let status = band(bytes, width: box.width, rows: max(0, box.height - 16)..<box.height)
        #expect(status.maxX <= 390 - 4 && status.maxX >= 390 - 8, "status reaches \(status.maxX)")
    }
}

@Suite("Modalities fill the column")
@MainActor
struct ModalityColumnTests {
    private let metrics = TranscriptMetrics(scale: 1, theme: .default)

    private func size(_ view: some View, width: CGFloat) -> CGSize {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return .zero }
        return CGSize(width: cg.width, height: cg.height)
    }

    @Test("The date input spans the whole column, wider than a 320pt card")
    func dateInput() {
        let renderer = ImageRenderer(content: ModalityDateInputView(metrics: metrics, isEnabled: true, onSubmit: { _ in })
            .frame(width: 390).fixedSize(horizontal: false, vertical: true))
        renderer.scale = 1
        // Ink across the row: the shell's tier-5 fill runs edge to edge.
        guard let cg = renderer.cgImage else { Issue.record("no image"); return }
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let y = cg.height / 2
        let filled = (0..<cg.width).filter { bytes[(y * cg.width + $0) * 4 + 3] > 0 }
        #expect((filled.max() ?? 0) - (filled.min() ?? 0) >= 380, "the date input spans \(filled.min() ?? 0)…\(filled.max() ?? 0)")
    }

    @Test("A video fills the column at 16:9")
    func video() throws {
        let video = ModalityVideo(url: try #require(URL(string: "https://example.com/v.mp4")), previewImageUrl: nil)
        let s = size(ModalityVideoView(video: video, metrics: metrics), width: 390)
        #expect(s.width == 390 && abs(s.height - 390 * 9 / 16) <= 1, "\(s)")
    }
}
