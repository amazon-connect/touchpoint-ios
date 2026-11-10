import SwiftUI
#if canImport(AVKit)
import AVKit
#endif
import TouchpointCore

// MARK: - Host modalities

/// What a host's modality view is given: the modality, whether it still takes input, and the
/// ways web's modality components answer (`interface.ts:72-97`).
@MainActor
public struct TouchpointModalityContext {
    /// The modality as the flow sent it.
    public let modality: TouchpointModality
    /// False once the customer has answered anything after this message — web's `enabled`.
    public let isEnabled: Bool
    /// Fill a slot, as a default modality's `$saveAs: {type: "slot"}` does. No customer bubble.
    public let sendSlot: @MainActor (_ id: String, _ value: String) -> Void
    /// Answer with a choice id, as `$saveAs: {type: "choiceId"}` does.
    public let sendChoice: @MainActor (_ id: String) -> Void
}

public extension View {
    /// Draws the host's own modality named `name` — web's `modalityComponents`. Register it once,
    /// above the chat. The four defaults (`DefaultCard`, `DefaultCarousel`, `DefaultDateInput`,
    /// `DefaultVideo`) **win** a clash, as web's merge has them (`App.tsx:124-127`).
    func touchpointModality<Content: View>(_ name: String,
                                           @ViewBuilder render: @escaping @MainActor (TouchpointModalityContext) -> Content) -> some View {
        transformEnvironment(\.touchpointModalityRenderers) { renderers in
            renderers[name] = { AnyView(render($0)) }
        }
    }
}

extension EnvironmentValues {
    @Entry var touchpointModalityRenderers: [String: @MainActor (TouchpointModalityContext) -> AnyView] = [:]
    /// How a modality answers: set by the transcript, read by every modality view below it.
    @Entry var touchpointModalityActions = ModalityActions()
    /// How a Connect View guide card resolves, opens and submits: set by the transcript, read by
    /// ``GuideCardView``. Empty (the default) leaves a guide card non-interactive.
    @Entry var touchpointGuideActions = GuideActions()
}

/// The transcript's hooks for a Connect View / guide card (A7). All optional: a chat with no
/// rendering configured leaves them `nil`, and the card keeps its non-interactive behaviour.
struct GuideActions {
    /// Resolve a `viewToken` into its definition (web's `describeView`). `nil` on failure.
    var describeView: (@MainActor (String) async -> ConnectViewDefinition?)?
    /// Submit a view action back to the flow (web's `submitView`). Returns whether it was queued.
    var submitView: (@MainActor (_ viewName: String?, _ action: String, _ data: Data) async -> Bool)?
    /// The host's instance-URL configuration. `nil` ⇒ guide cards do not open.
    var rendering: ConnectViewRendering?
    /// Report a security-relevant rejection the renderer web view made at runtime — a navigation to
    /// a foreign origin that the navigation delegate refused (I6, BSC40). Routed to the host's error
    /// stream. `nil` ⇒ not wired (the navigation is still refused regardless).
    var onSecurityRejection: (@MainActor (TouchpointError) -> Void)?

    /// Everything a card needs to open: rendering configured and a resolver wired.
    var canOpen: Bool { rendering != nil && describeView != nil }
}

/// The transcript's answers for modalities. Package-internal; hosts see them through
/// ``TouchpointModalityContext``.
struct ModalityActions {
    var sendSlot: @MainActor (String, String) -> Void = { _, _ in }
    var sendChoice: @MainActor (String) -> Void = { _ in }

    /// Web's `saveFn` (`shared.ts:34-53`). `context` would go to Live Sync's context endpoint;
    /// **deviation:** the chat has no Live Sync handle, so it is not sent, and the flows this SDK is
    /// tested against save to slots.
    @MainActor func save(_ target: TouchpointModalitySaveTarget?, _ value: String) {
        guard let target else { return }
        switch target.type {
        case .slot: sendSlot(target.id, value)
        case .choiceId: sendChoice(value)
        case .context: break
        }
    }
}

// MARK: - The transcript's modality stack

/// Every modality a message carries, in the flow's order, under its text. An unknown modality draws
/// nothing, as web's does (`Messages.tsx:763-768`, a console warning there).
@MainActor
struct TranscriptModalitiesView: View {
    @Environment(\.touchpointModalityRenderers) private var renderers
    @Environment(\.touchpointModalityActions) private var actions
    let message: Message
    let metrics: TranscriptMetrics
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.messageSpacing) {
            if let reference = message.interactive?.viewReference {
                GuideCardView(reference: reference, metrics: metrics)
            }
            ForEach(message.interactive?.modalities ?? []) { modality in
                modalityView(modality)
            }
        }
    }

    @ViewBuilder
    private func modalityView(_ modality: TouchpointModality) -> some View {
        switch modality.name {
        case "DefaultCard":
            if let card = try? JSONDecoder().decode(ModalityCard.self, from: modality.json) {
                ModalityCardView(card: card, metrics: metrics)
            }
        case "DefaultCarousel":
            if let carousel = try? JSONDecoder().decode(ModalityCarousel.self, from: modality.json) {
                ModalityCarouselView(carousel: carousel, metrics: metrics, isEnabled: isEnabled) { id in
                    actions.save(carousel.saveAs, id)
                }
            }
        case "DefaultDateInput":
            let input = (try? JSONDecoder().decode(ModalitySaveOnly.self, from: modality.json)) ?? ModalitySaveOnly(saveAs: nil)
            ModalityDateInputView(metrics: metrics, isEnabled: isEnabled && input.saveAs != nil) { date in
                actions.save(input.saveAs, date)
            }
        case "DefaultVideo":
            if let video = try? JSONDecoder().decode(ModalityVideo.self, from: modality.json) {
                ModalityVideoView(video: video, metrics: metrics)
            }
        default:
            if let render = renderers[modality.name] {
                render(TouchpointModalityContext(modality: modality, isEnabled: isEnabled,
                                                 sendSlot: { actions.sendSlot($0, $1) }, sendChoice: { actions.sendChoice($0) }))
                    // A host's view keeps its full height: in participant info's narrower column
                    // SwiftUI compressed a host's card by a couple of points and its text
                    // clipped, which the accessibility audit caught.
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Default modality data (web `components/defaultModalities/shared.ts`)

struct ModalityCard: Decodable, Equatable {
    struct Row: Decodable, Equatable { let label: String; let value: String }
    let id: String?
    let thumbnail: URL?
    let thumbnailAlt: String?
    let rows: [Row]

    enum CodingKeys: String, CodingKey { case id, thumbnail, thumbnailAlt, rows, label, value }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        thumbnail = (try? c.decodeIfPresent(String.self, forKey: .thumbnail)).flatMap { $0 }.flatMap(URL.init(string:))
        thumbnailAlt = try c.decodeIfPresent(String.self, forKey: .thumbnailAlt)
        var rows = (try? c.decodeIfPresent([Row].self, forKey: .rows)) ?? []
        // A card may carry a single label/value instead of rows.
        if rows.isEmpty, let label = try c.decodeIfPresent(String.self, forKey: .label),
           let value = try c.decodeIfPresent(String.self, forKey: .value) {
            rows = [Row(label: label, value: value)]
        }
        self.rows = rows
    }
    init(id: String?, thumbnail: URL? = nil, thumbnailAlt: String? = nil, rows: [Row]) {
        self.id = id; self.thumbnail = thumbnail; self.thumbnailAlt = thumbnailAlt; self.rows = rows
    }
}

struct ModalityCarousel: Decodable, Equatable {
    let cards: [ModalityCard]
    let saveAs: TouchpointModalitySaveTarget?
    enum CodingKeys: String, CodingKey { case cards, saveAs = "$saveAs" }
}

struct ModalitySaveOnly: Decodable, Equatable {
    let saveAs: TouchpointModalitySaveTarget?
    enum CodingKeys: String, CodingKey { case saveAs = "$saveAs" }
}

struct ModalityVideo: Decodable, Equatable {
    let url: URL
    let previewImageUrl: URL?
}

// MARK: - Views

/// Web's `CustomCard`: `rounded-inner bg-secondary-40`, a hairline `primary-10` border that turns
/// accent when selected, an optional 208pt image row, then label/value rows.
@MainActor
struct ModalityCardView: View {
    @Environment(\.touchpointTheme) private var theme
    let card: ModalityCard
    let metrics: TranscriptMetrics
    var selected = false
    /// Drawn as a carousel button's label.
    var isButtonLabel = false

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.hairline) {
            if let url = card.thumbnail {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { theme.primary(.t5) }
                    .frame(height: metrics.modalityCardImageHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .accessibilityLabel(card.thumbnailAlt ?? "")
                    .accessibilityHidden(card.thumbnailAlt == nil)
            }
            ForEach(Array(card.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: metrics.controlPadding) {
                    Text(row.label).foregroundStyle(theme.primary(.t60))
                    Spacer(minLength: metrics.controlPadding)
                    Text(row.value).foregroundStyle(theme.primary(.t90)).multilineTextAlignment(.trailing)
                }
                .font(metrics.bodyFont)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, metrics.modalityCardRowHorizontalPadding)
                .padding(.vertical, metrics.modalityCardRowVerticalPadding)
                // One element per row on a plain card; inside a carousel button the button itself
                // is the one element — a nested element there swallowed the button's hit test.
                .accessibilityElement(children: isButtonLabel ? .contain : .combine)
            }
        }
        .frame(maxWidth: metrics.modalityCardWidth, alignment: .leading)
        .background(theme.secondary(.t40), in: TouchpointShape.rounded(metrics.innerRadius))
        .clipShape(TouchpointShape.rounded(metrics.innerRadius))
        .overlay {
            TouchpointShape.rounded(metrics.innerRadius)
                .strokeBorder(selected ? theme.accent : theme.primary(.t10),
                              lineWidth: selected ? metrics.modalitySelectedBorderWidth : metrics.hairline)
        }
    }
}

/// Web's `DefaultCarousel`: the cards side by side, scrolling; a card with an id is a button that
/// saves it (`$saveAs`) and reads selected from then on.
@MainActor
struct ModalityCarouselView: View {
    let carousel: ModalityCarousel
    let metrics: TranscriptMetrics
    let isEnabled: Bool
    let onPick: (String) -> Void
    @State private var picked: String?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: metrics.controlPadding) {
                ForEach(Array(carousel.cards.enumerated()), id: \.offset) { _, card in
                    if let id = card.id, carousel.saveAs != nil {
                        Button {
                            picked = id
                            onPick(id)
                        } label: {
                            ModalityCardView(card: card, metrics: metrics, selected: picked == id, isButtonLabel: true)
                                .containerRelativeFrame(.horizontal) { length, _ in Self.cardWidth(in: length, metrics: metrics) }
                                .contentShape(TouchpointShape.rounded(metrics.innerRadius))
                        }
                        .buttonStyle(.plain)
                        .disabled(!isEnabled || picked != nil)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(card.rows.map { "\($0.label), \($0.value)" }.joined(separator: ", "))
                        .accessibilityAddTraits(picked == id ? [.isButton, .isSelected] : .isButton)
                    } else {
                        ModalityCardView(card: card, metrics: metrics)
                            .containerRelativeFrame(.horizontal) { length, _ in Self.cardWidth(in: length, metrics: metrics) }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        // Web's carousel bleeds into the transcript's padding (`Carousel.tsx`, `px-2 -mx-2`), so
        // the next card runs to the panel's edge rather than being cut at the text column (QA c33).
        // Trailing only: the first card stays aligned with the message text, which a leading bleed
        // would break under participant info's avatar column. The matching content margin lets the
        // last card scroll back into the column.
        .contentMargins(.trailing, metrics.transcriptHorizontalPadding, for: .scrollContent)
        .padding(.trailing, -metrics.transcriptHorizontalPadding)
    }

    /// Web's card is `w-80` (320) in the carousel as everywhere else; never wider than the scroll
    /// view's container length (the column, its trailing content margin excluded), which at
    /// accessibility text sizes would otherwise make one card wider than the screen.
    static func cardWidth(in length: CGFloat, metrics: TranscriptMetrics) -> CGFloat {
        min(metrics.modalityCardWidth, max(0, length))
    }
}

/// Web's `DefaultDateInput`: pick a date, send it as `YYYY-MM-DD`. **Deviation:** the system date
/// picker instead of web's masked `MM / DD / YYYY` text field — on a phone the picker is the input.
@MainActor
struct ModalityDateInputView: View {
    @Environment(\.touchpointTheme) private var theme
    let metrics: TranscriptMetrics
    let isEnabled: Bool
    let onSubmit: (String) -> Void
    @State private var date = Date()
    @State private var sent = false

    static func wireValue(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    var body: some View {
        HStack(spacing: metrics.controlPadding) {
            TouchpointIconView(.date, size: metrics.iconGlyphSize).foregroundStyle(theme.primary(.t60))
            DatePicker(TouchpointStrings.modalityDateLabel, selection: $date, displayedComponents: .date)
                .labelsHidden()
                .disabled(!isEnabled || sent)
            Spacer(minLength: 0)
            Button {
                sent = true
                onSubmit(Self.wireValue(date))
            } label: {
                TouchpointIconView(.arrowForward)
            }
            // Web's date submit is IconButton `main` with ArrowForward (c36).
            .buttonStyle(TouchpointIconButtonStyle(.accent))
            .disabled(!isEnabled || sent)
            .accessibilityLabel(TouchpointStrings.modalityDateSubmitLabel)
        }
        .padding(.leading, metrics.controlPaddingWide)
        .padding(.trailing, metrics.controlPadding)
        .padding(.vertical, metrics.controlGap)
        // Web's date input fills the message column (c38).
        .frame(maxWidth: .infinity)
        .background(theme.primary(.t5), in: TouchpointShape.rounded(metrics.outerRadius))
        .overlay { TouchpointShape.rounded(metrics.outerRadius).strokeBorder(theme.primary(.t10), lineWidth: metrics.hairline) }
    }
}

/// Web's `DefaultVideo`: a poster with a play button; playing hands over to the system player.
@MainActor
struct ModalityVideoView: View {
    @Environment(\.touchpointTheme) private var theme
    let video: ModalityVideo
    let metrics: TranscriptMetrics
    @State private var playing = false

    var body: some View {
        ZStack {
            #if canImport(AVKit)
            if playing {
                VideoPlayer(player: AVPlayer(url: video.url))
            } else {
                poster
            }
            #else
            poster
            #endif
        }
        // Web's video fills the message column at 16:9 (`DefaultVideo.tsx`, `w-full`; c40).
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(TouchpointShape.rounded(metrics.innerRadius))
    }

    private var poster: some View {
        Button { playing = true } label: {
            ZStack {
                if let preview = video.previewImageUrl {
                    AsyncImage(url: preview) { $0.resizable().scaledToFill() } placeholder: { Color.black }
                } else {
                    Color.black
                }
                Color.black.opacity(0.3)
                // Web's Play at 28 in a 56 disc, `bg-black/50 backdrop-blur-sm` (`DefaultVideo.tsx:71`).
                // The material is forced dark so the disc reads the same on any poster (c46).
                TouchpointIconView(.play, size: metrics.modalityPlayGlyphSize)
                    .foregroundStyle(.white)
                    .frame(width: metrics.modalityPlayButtonDiameter, height: metrics.modalityPlayButtonDiameter)
                    .background {
                        ZStack {
                            Circle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                            Circle().fill(.black.opacity(0.5))
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(TouchpointStrings.modalityPlayVideoLabel)
    }
}

/// Web's guide card for a Connect View (`GuideCard.tsx`). When the host has configured
/// ``ConnectViewRendering`` it is a button: the heading/subheading, a status badge
/// (notStarted → inProgress on open → complete after a submit), and tapping it resolves the view
/// and opens the renderer in a full-screen sheet. With no rendering configured it keeps the
/// non-interactive card — heading/subheading and a note that the form continues with an agent.
///
/// **Deviation:** web resolves the view on mount (to show `view.name` as the title and to disable
/// the card until it loads); this SDK resolves **on tap**, showing the view data's `Heading` until
/// then, to avoid a `describeView` round trip for every guide card as it scrolls into view.
@MainActor
struct GuideCardView: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.touchpointGuideActions) private var guide
    let reference: ConnectViewReference
    let metrics: TranscriptMetrics

    /// Local (non-protocol) progress, exactly as web keeps it (`GuideCard.tsx:GuideStatus`).
    enum GuideStatus: String { case notStarted, inProgress, complete }
    enum Phase: Equatable { case idle, resolving, failed }

    @State private var status: GuideStatus = .notStarted
    @State private var phase: Phase = .idle
    @State private var open: OpenGuide?

    struct OpenGuide: Identifiable {
        let id = UUID()
        let definition: ConnectViewDefinition
        let viewData: Data?
    }

    private var title: String {
        open?.definition.name ?? reference.heading ?? TouchpointStrings.guideDefaultTitle
    }

    var body: some View {
        #if canImport(UIKit) && canImport(WebKit)
        if guide.canOpen, reference.viewToken != nil {
            interactiveCard
        } else {
            staticCard
        }
        #else
        staticCard
        #endif
    }

    // MARK: Non-interactive (no rendering configured) — today's card

    private var staticCard: some View {
        cardSurface {
            Text(reference.heading ?? TouchpointStrings.guideDefaultTitle)
                .font(metrics.bodyFont).foregroundStyle(theme.primary(.t90))
            if let subheading = reference.subheading { Text(subheading).font(metrics.smallFont).foregroundStyle(theme.primary(.t60)) }
            Text(TouchpointStrings.guideUnsupported).font(metrics.smallFont).foregroundStyle(theme.primary(.t60))
        }
        .accessibilityElement(children: .combine)
    }

    #if canImport(UIKit) && canImport(WebKit)
    // MARK: Interactive (rendering configured)

    private var interactiveCard: some View {
        Button { openTapped() } label: {
            cardSurface {
                HStack(spacing: metrics.controlGap) {
                    Text(TouchpointStrings.guideLabel).font(metrics.smallFont).foregroundStyle(theme.primary(.t60))
                    Spacer(minLength: 0)
                    GuideStatusBadge(status: status, metrics: metrics)
                }
                Text(reference.heading ?? TouchpointStrings.guideDefaultTitle)
                    .font(metrics.bodyFont).foregroundStyle(theme.primary(.t90))
                if phase == .resolving {
                    Text(TouchpointStrings.guideLoading).font(metrics.smallFont).foregroundStyle(theme.primary(.t40))
                } else if phase == .failed {
                    Text(TouchpointStrings.guideError).font(metrics.smallFont).foregroundStyle(theme.error)
                } else if let subheading = reference.subheading {
                    Text(subheading).font(metrics.smallFont).foregroundStyle(theme.primary(.t60))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(phase == .resolving)
        .accessibilityElement(children: .combine)
        .accessibilityHint(TouchpointStrings.guideOpenHint)
        .fullScreenCover(item: $open) { open in
            if let rendering = guide.rendering {
                GuideModalView(
                    title: title,
                    viewName: open.definition.name,
                    definition: open.definition,
                    viewData: open.viewData,
                    rendering: rendering,
                    onSubmit: { viewName, action, data in
                        Task { _ = await guide.submitView?(viewName, action, data) }
                    },
                    onComplete: { status = .complete },
                    onClose: { self.open = nil },
                    onSecurityRejection: guide.onSecurityRejection)
                .touchpointTheme(theme)
            }
        }
    }

    private func openTapped() {
        guard phase != .resolving, let token = reference.viewToken, let describe = guide.describeView else { return }
        phase = .resolving
        Task {
            let resolved = await describe(token)
            guard let resolved else { phase = .failed; return }
            phase = .idle
            if status == .notStarted { status = .inProgress }   // web: inProgress on open
            open = OpenGuide(definition: resolved, viewData: reference.viewData)
        }
    }
    #endif

    @ViewBuilder
    private func cardSurface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: metrics.controlPaddingWide) {
            TouchpointIconView(.guide, size: metrics.iconGlyphSize).foregroundStyle(theme.primary(.t60))
            VStack(alignment: .leading, spacing: metrics.controlGap) { content() }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(metrics.controlPaddingWide)
        .frame(maxWidth: metrics.modalityCardWidth, alignment: .leading)
        .background(theme.secondary(.t40), in: TouchpointShape.rounded(metrics.innerRadius))
        .overlay { TouchpointShape.rounded(metrics.innerRadius).strokeBorder(theme.primary(.t10), lineWidth: metrics.hairline) }
    }
}

/// Web's `StatusBadge` (`GuideCard.tsx:48-61`): a small pill whose colour and copy track the local
/// guide status.
@MainActor
struct GuideStatusBadge: View {
    @Environment(\.touchpointTheme) private var theme
    let status: GuideCardView.GuideStatus
    let metrics: TranscriptMetrics

    var body: some View {
        Text(label)
            .font(metrics.smallFont)
            .foregroundStyle(foreground)
            .padding(.horizontal, metrics.controlGap)
            .padding(.vertical, metrics.hairline)
            .background(background, in: .capsule)
    }

    private var label: String {
        switch status {
        case .notStarted: return TouchpointStrings.guideStatusNotStarted
        case .inProgress: return TouchpointStrings.guideStatusInProgress
        case .complete: return TouchpointStrings.guideStatusComplete
        }
    }
    // Web: notStarted → primary, inProgress → warning, complete → accent.
    private var foreground: Color {
        switch status {
        case .notStarted: return theme.primary(.t60)
        case .inProgress: return theme.primary(.t90)
        case .complete: return theme.accent
        }
    }
    private var background: Color {
        switch status {
        case .notStarted: return theme.primary(.t10)
        case .inProgress: return theme.secondary(.t40)
        case .complete: return theme.accent.opacity(0.2)
        }
    }
}
