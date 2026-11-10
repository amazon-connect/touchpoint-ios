#if canImport(UIKit)
import SwiftUI
import Testing
import TouchpointCore
@testable import TouchpointChat

/// Transcript snapshots. These assert **properties of the rendering, not pixels**: a golden PNG churns
/// on every OS bump and would not have caught the defect scaled metrics exist to prevent, which is a
/// transcript that stops growing when the user's text size does. Rendering happens through SwiftUI's
/// own `ImageRenderer`, so there is no third-party test dependency in a published SDK.
@Suite("Transcript snapshots", .serialized)
@MainActor
struct TranscriptSnapshotTests {
    private static let conversation = [
        Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s1", body: "Hello — how can I help with your account today?", direction: .inbound, participantRole: .assistant, sequence: 1, deliveryState: .delivered)),
        Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s2", body: "I am disputing a charge from last Tuesday.", direction: .outbound, participantRole: .customer, sequence: 2, deliveryState: .read)),
        Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s3", body: "Of course. I can see a pending transaction — let me pull the details.", direction: .inbound, participantRole: .assistant, sequence: 3, deliveryState: .delivered)),
    ]

    /// The rows, on the surface, at a fixed width so height is the only free dimension. Rows rather
    /// than the whole `ChatTranscriptView`: its `LazyVStack` inside a `ScrollView` does not
    /// materialise under `ImageRenderer` (a harness limit, not a product one — an app's UI test
    /// drives the real thing), and the rows are what these properties are about.
    ///
    /// `onSurface: false` omits the panel, leaving only what the rows themselves draw. That makes
    /// alpha the signal: the customer's bubble is a 10%-alpha fill, text is 60–80%. Over the real
    /// surface those distinctions are swamped by its own wash and sheen.
    private func render(
        _ messages: [Message] = conversation,
        typeSize: DynamicTypeSize = .large,
        colorScheme: ColorScheme = .light,
        layoutDirection: LayoutDirection = .leftToRight,
        width: CGFloat = 390,
        onSurface: Bool = true
    ) -> (image: UIImage, size: CGSize) {
        let rows = TranscriptLayout.rows(for: messages)
        let metrics = TranscriptMetrics(scale: TranscriptMetrics.scale(for: typeSize))
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                MessageRow(row: row, metrics: metrics, canRetry: true, feedbackGiven: nil,
                           onRetry: { _ in true }, onFeedback: nil)
                    // The same rule the view uses, so this harness measures what ships.
                    .padding(.top, TranscriptLayout.topSpacing(index: index, metrics: metrics))
            }
        }
        .padding(metrics.transcriptPadding)
        .frame(width: width)
        let view = Group {
            if onSurface { content.background(TouchpointSurface()) } else { content }
        }
        .environment(\.dynamicTypeSize, typeSize)
        .environment(\.colorScheme, colorScheme)
        .environment(\.layoutDirection, layoutDirection)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.uiImage else { return (UIImage(), .zero) }
        return (image, image.size)
    }

    @Test("Height grows monotonically with Dynamic Type — the transcript has no fixed heights")
    func heightGrowsWithTextSize() {
        let sizes: [DynamicTypeSize] = [.xSmall, .large, .xxxLarge, .accessibility3, .accessibility5]
        let heights = sizes.map { render(typeSize: $0).size.height }
        #expect(heights.allSatisfy { $0 > 0 })
        for (a, b) in zip(heights, heights.dropFirst()) {
            #expect(b > a, "height did not grow: \(heights)")
        }
        // The largest accessibility size must be materially taller, not nudged by a point or two.
        #expect(heights.last! > heights.first! * 1.5, "heights: \(heights)")
    }

    @Test("The surface and its ink follow the colour scheme: a light panel with dark ink, a dark panel with light ink")
    func darkModeDiffers() {
        // Measured, not byte-compared: comparing PNG bytes would also "pass" on an antialiasing
        // change and could fail for reasons unrelated to the tokens. The transcript draws its own
        // `TouchpointSurface`, so both the panel and the ink on it are asserted.
        let light = render(colorScheme: .light).image, dark = render(colorScheme: .dark).image
        let lightSurface = Self.surfaceLuminance(light), darkSurface = Self.surfaceLuminance(dark)
        #expect(lightSurface > 0.8, "light surface \(lightSurface)")
        #expect(darkSurface < 0.2, "dark surface \(darkSurface)")
        let lightInk = Self.meanInkLuminance(light), darkInk = Self.meanInkLuminance(dark)
        #expect(lightInk < lightSurface - 0.3, "light ink \(lightInk) on \(lightSurface)")
        #expect(darkInk > darkSurface + 0.3, "dark ink \(darkInk) on \(darkSurface)")
    }

    @Test("Right-to-left mirrors the layout: the content's weight moves to the other side")
    func rtlMirrors() {
        // The transcript is agent-heavy, so its ink sits left of centre in LTR and right of centre
        // when mirrored. A measured centroid says that; a byte difference does not.
        let ltr = Self.inkCentroidX(render(layoutDirection: .leftToRight).image)
        let rtl = Self.inkCentroidX(render(layoutDirection: .rightToLeft).image)
        #expect(ltr < 0.5, "LTR centroid \(ltr) should sit left of centre")
        #expect(rtl > 0.5, "RTL centroid \(rtl) should sit right of centre")
    }

    @Test("Asymmetric transcript (design-01): the assistant's plain text on the leading side, the customer's tinted bubble on the trailing side")
    func asymmetry() {
        let assistant = [Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s1", body: "Short reply.", direction: .inbound, participantRole: .assistant, sequence: 1, deliveryState: .delivered))]
        let customer = [Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s2", body: "Short ask.", direction: .outbound, participantRole: .customer, sequence: 2, deliveryState: .read))]
        // Sides, measured on the surface the way a reader sees it.
        let a = Self.inkCentroidX(render(assistant).image), c = Self.inkCentroidX(render(customer).image)
        #expect(a < 0.4, "assistant centroid \(a) should sit on the leading side")
        #expect(c > 0.6, "customer centroid \(c) should sit on the trailing side")
        // Bubble or no bubble, measured off the surface so alpha is the signal: the customer's words
        // sit on a 10%-alpha fill, the assistant's on nothing.
        let ct = Self.faintFillFraction(render(customer, onSurface: false).image)
        let at = Self.faintFillFraction(render(assistant, onSurface: false).image)
        #expect(ct > at * 3, "customer fill \(ct) assistant fill \(at)")
        #expect(at < 0.02, "the assistant's message must not draw a bubble: \(at)")
    }

    @Test("Feedback controls render only when the host listens, and the chosen thumb reads stronger than its sibling")
    func feedbackControlsRender() {
        let assistant = Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s1", body: "Here you go.",
                                              direction: .inbound, participantRole: .assistant, sequence: 1,
                                              deliveryState: .delivered))
        let row = TranscriptLayout.rows(for: [assistant])[0]
        let metrics = TranscriptMetrics(scale: 1)
        func render(given: MessageFeedback?, listening: Bool) -> UIImage {
            var handler: (@MainActor (Message, MessageFeedback) -> Void)?
            if listening { handler = { _, _ in } }
            let view = MessageRow(row: row, metrics: metrics, canRetry: false, feedbackGiven: given,
                                  onRetry: { _ in true }, onFeedback: handler)
                .frame(width: 390)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            return renderer.uiImage ?? UIImage()
        }
        // Three controls instead of one, measured in the action row's own band so the constant
        // message text above does not dilute the ratio.
        let withFeedback = Self.inkArea(render(given: nil, listening: true), yRange: 0.6...1.0)
        let copyOnly = Self.inkArea(render(given: nil, listening: false), yRange: 0.6...1.0)
        #expect(withFeedback > copyOnly * 2, "with feedback \(withFeedback) copy only \(copyOnly)")
        // A chosen thumb is filled, so it carries more ink than the same row unchosen.
        let chosen = Self.inkArea(render(given: .positive, listening: true), yRange: 0.6...1.0)
        #expect(chosen > withFeedback, "chosen \(chosen) unchosen \(withFeedback)")
    }

    /// Count of drawn pixels in a horizontal band — a proxy for "how many controls are drawn".
    /// Alpha-based, because the row is rendered without a surface here.
    private static func inkArea(_ image: UIImage, yRange: ClosedRange<Double> = 0...1) -> Double {
        guard let pixels = pixelData(image) else { return 0 }
        var n = 0.0
        let y0 = Int(Double(pixels.height) * yRange.lowerBound), y1 = Int(Double(pixels.height) * yRange.upperBound)
        for y in y0..<max(y0 + 1, y1) {
            for x in 0..<pixels.width where Double(pixels.bytes[(y * pixels.width + x) * 4 + 3]) / 255 > 0.05 {
                n += 1
            }
        }
        return n
    }

    @Test("At 200% text the content reflows into more lines rather than being clipped (WCAG 1.4.10)")
    func reflowsAtDoubleSize() {
        // A pinned frame makes any width assertion tautological, so this measures the thing that
        // actually distinguishes reflow from clipping: at half the width, the same text at the same
        // size must occupy *more* vertical space.
        let wide = render(typeSize: .accessibility3, width: 420).size.height
        let narrow = render(typeSize: .accessibility3, width: 210).size.height
        #expect(narrow > wide, "narrow=\(narrow) wide=\(wide): text did not reflow")
    }

    @Test("Every presentation case the SDK ships actually renders its chat surface")
    func everyPresentationCaseRenders() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-snap-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        let store = try await ConversationStore(containerURL: dir, keychain: keychain)
        let session = TouchpointSession(broker: CredentialBroker(backend: NoBackend(), keychain: keychain), store: store, transports: [:])
        // `ImageRenderer` renders the tree it is given and does **not** materialise sheet content,
        // so asserting on `.touchpointChat(...)` would only prove the host's own view rendered.
        // What both cases share — and all either one adds chrome around — is this surface.
        for presentation in TouchpointPresentation.allCasesBuilt {
            let header: ChatHeader? = presentation == .embedded ? nil : ChatHeader(title: "Support")
            let surface = TouchpointChatView(session: session, header: header, onClose: {})
                .frame(width: 390, height: 600)
            #expect(ImageRenderer(content: surface).uiImage != nil, "\(presentation) did not render")
        }
    }

    // MARK: Pixel probes
    //
    // Properties of the rendering, not golden bytes: a PNG churns on every OS bump and would not
    // have caught the defect scaled metrics exist to prevent. The transcript now draws an opaque, textured
    // surface, so "ink" is defined relative to the panel rather than against transparency.

    /// The most common luminance in the frame — the panel itself.
    private static func surfaceLuminance(_ image: UIImage) -> Double {
        guard let pixels = pixelData(image) else { return 0 }
        var histogram = [Int](repeating: 0, count: 64)
        for i in stride(from: 0, to: pixels.bytes.count, by: 4) {
            histogram[min(63, Int(luminance(pixels.bytes, i) * 63))] += 1
        }
        let mode = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0
        return Double(mode) / 63
    }

    private static func luminance(_ bytes: [UInt8], _ i: Int) -> Double {
        let a = Double(bytes[i + 3]) / 255
        guard a > 0 else { return 0 }
        // Premultiplied: recover the colour before measuring it.
        let r = Double(bytes[i]) / a, g = Double(bytes[i + 1]) / a, b = Double(bytes[i + 2]) / a
        return min(1, (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255)
    }

    /// Ink: a pixel that contrasts strongly with the panel — text and glyphs, not a bubble's tint.
    private static func isInk(_ bytes: [UInt8], _ i: Int, surface: Double) -> Bool {
        abs(luminance(bytes, i) - surface) > 0.3
    }

    private static func meanInkLuminance(_ image: UIImage) -> Double {
        guard let pixels = pixelData(image) else { return 0 }
        let surface = surfaceLuminance(image)
        var total = 0.0, count = 0.0
        for i in stride(from: 0, to: pixels.bytes.count, by: 4) where isInk(pixels.bytes, i, surface: surface) {
            total += luminance(pixels.bytes, i)
            count += 1
        }
        return count > 0 ? total / count : 0
    }

    /// Horizontal centre of mass of ink pixels, as a fraction of width (0 = left edge).
    private static func inkCentroidX(_ image: UIImage) -> Double {
        guard let pixels = pixelData(image) else { return 0.5 }
        let surface = surfaceLuminance(image)
        var weighted = 0.0, mass = 0.0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let i = (y * pixels.width + x) * 4
                guard isInk(pixels.bytes, i, surface: surface) else { continue }
                weighted += Double(x)
                mass += 1
            }
        }
        guard mass > 0 else { return 0.5 }
        return weighted / mass / Double(pixels.width)
    }

    /// Fraction of pixels drawn at a faint alpha, over a transparent backdrop — a bubble or a well,
    /// never text (which is drawn at tier 60 or above).
    private static func faintFillFraction(_ image: UIImage) -> Double {
        guard let pixels = pixelData(image) else { return 0 }
        var n = 0.0
        for i in stride(from: 0, to: pixels.bytes.count, by: 4) {
            let a = Double(pixels.bytes[i + 3]) / 255
            if a > 0.03 && a < 0.3 { n += 1 }
        }
        return n / Double(pixels.width * pixels.height)
    }

    private static func pixelData(_ image: UIImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }

    // No in-process accessibility-tree test lives here. SwiftUI materialises its accessibility
    // elements only for a real assistive-technology client, so a `UIHostingController` walk returns
    // an empty list in a unit-test process — and an assertion over an empty list passes while
    // proving nothing. The audit that does work is `performAccessibilityAudit()` in a running
    // app's UI test, which drives the app through XCUITest.
}

/// Never vends: the presentation snapshot asserts layout, not behaviour.
private struct NoBackend: TouchpointBackend {
    func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials { throw TouchpointError.contactNotFound }
    func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials { throw TouchpointError.contactNotFound }
    func liveSyncCredentials() async throws -> LiveSyncCredentials { throw TouchpointError.contactNotFound }
}
#endif
