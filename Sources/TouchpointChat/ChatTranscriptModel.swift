import Foundation
import Observation
import TouchpointCore

/// Presentation-only derivations from a list of `Message` values: who to name, where a group ends,
/// which delivery state to show. Pure and synchronous so it is testable without a view.
enum TranscriptLayout {
    struct Row: Identifiable, Equatable {
        let message: Message
        /// Delivery state is shown for the newest outbound message, and for any failed one. Showing
        /// a tick on every bubble is noise; hiding a failure is a lie.
        let showsDeliveryState: Bool
        /// Copy hangs off the end of an inbound run — never the customer's own words, never a
        /// `.system` notice, and never a half-written streaming reply.
        let showsActions: Bool
        /// Feedback is about the **assistant's** answer (design-01). A human agent's reply is not
        /// rated, and neither is a system notice.
        let allowsFeedback: Bool
        var id: UUID { message.clientMessageID }

        var isRetryable: Bool { message.deliveryState == .failed }
    }

    /// The gap above a row. One rule, so the snapshot harness cannot drift from what ships — it
    /// did: the harness kept the old `startsResponse` ternary after the view moved to a uniform gap.
    ///
    /// Web appends every inbound Connect message as its own `Response` (`conversation.ts:566-569`,
    /// a plain append with no merging), and the container is `space-y-8`, so consecutive messages —
    /// on either side — sit 32px apart. Web's 8px `space-y-2` applies only *within* one
    /// multi-message payload, which the transport does not surface yet.
    package static func topSpacing(index: Int, metrics: TranscriptMetrics) -> CGFloat {
        index == 0 ? 0 : metrics.responseSpacing
    }

    /// Whether the welcome layout is used at all. Not in the phone's bottom-half dock: web has no
    /// half-height panel on a phone (its `half` covers the screen below 768px), so the design file
    /// decides there, and it centres no welcome group in a half-height dock (QA c16). The tablet's
    /// right-half panel and the full and mini windows keep it.
    package static func showsWelcomeScreen(enabled: Bool, isBottomDock: Bool) -> Bool {
        enabled && !isBottomDock
    }

    /// The opening assistant turn, while it is still the whole conversation — what web calls the
    /// welcome screen (`App.tsx:630-664`). Centred instead of top-anchored, so a first-time panel
    /// does not look like an empty transcript with one line stranded at the top.
    ///
    /// `nil` means "draw the ordinary transcript". An **empty** array is not the same thing: it is
    /// the connecting phase, where web shows a centred status and no transcript at all.
    ///
    /// It survives a second assistant message (so the greeting does not flash away mid-turn) and
    /// ends the moment the customer sends anything. Like web it also gives up for anything that is
    /// not a plain assistant message — a system notice, a human agent's reply, or a message
    /// carrying a card — none of which belong centred.
    package static func welcome(for messages: [Message], isEnded: Bool, hasNotices: Bool = false) -> [Message]? {
        // Web leaves the welcome screen for any response that is not an assistant message — a
        // Notice or a Failure among them (`App.tsx:630-664`).
        guard !isEnded, !hasNotices else { return nil }
        var opening: [Message] = []
        for message in messages {
            if message.direction == .outbound { return nil }                // the customer has begun
            // Connect's flow and the assistant both speak as SYSTEM; web counts every non-agent
            // message as the bot's (`conversation.ts:883`). A human agent's ends it.
            guard Self.isBot(message) else { return nil }
            // Cards do not belong centred; a message that only offers replies does — web keeps the
            // welcome screen for choices and lifts the composer up with them (`App.tsx:863-893`).
            guard !(message.interactive?.carriesCard ?? false) else { return nil }
            opening.append(message)
        }
        return opening
    }

    /// The replies on offer: the choices of the newest message from the other side, until the
    /// customer answers it — by taking a choice or by typing, either of which appends a message of
    /// ours after it (`App.tsx:596-627`). Web hides them "immediately instead of waiting for the
    /// next assistant reply", and so does this.
    ///
    /// Only the newest such message counts: choices on an older one are not re-offered once a
    /// newer message without any has arrived. Every inbound message counts, SYSTEM included: Connect
    /// sends its flow's and the assistant's messages — the showcase menu among them — as SYSTEM, and
    /// web makes each an application response (`conversation.ts:883`). The SDK's own notices are not
    /// messages, so nothing here needs excluding.
    package static func choices(for messages: [Message]) -> [InteractiveChoice] {
        guard let last = messages.lastIndex(where: { $0.direction == .inbound }) else { return [] }
        guard !messages[(last + 1)...].contains(where: { $0.direction == .outbound }) else { return [] }
        return messages[last].interactive?.choices ?? []
    }

    /// Whether a message has anything to draw: words, a modality the transcript renders, or a
    /// Connect View's guide card.
    ///
    /// A message can arrive with an empty body: an interactive payload whose text could not be
    /// found, a slot pick of our own (which web draws no bubble for), or a modality with no
    /// message text. Those without a modality or view are suppressed rather than drawn as a
    /// **blank row** — a gap with a delivery tick and nothing else.
    package static func isRenderable(_ message: Message) -> Bool {
        if !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if message.attachment != nil { return true }   // the pill draws its name, either direction
        guard message.direction == .inbound, let interactive = message.interactive else { return false }
        return !interactive.modalities.isEmpty || interactive.viewSummary != nil
    }

    /// The message whose modalities still take input: the newest from the other side, until the
    /// customer answers anything after it — the same rule as ``choices(for:)``. Web passes
    /// `enabled` only to the latest response's modalities.
    package static func answerableMessageID(in messages: [Message]) -> UUID? {
        guard let last = messages.lastIndex(where: { $0.direction == .inbound }) else { return nil }
        guard !messages[(last + 1)...].contains(where: { $0.direction == .outbound }) else { return nil }
        return messages[last].id
    }

    static func rows(for messages: [Message]) -> [Row] {
        let messages = messages.filter(isRenderable)
        let lastOutbound = messages.lastIndex { $0.direction == .outbound }
        return messages.indices.map { i in
            let m = messages[i]
            let previous = i > 0 ? messages[i - 1] : nil
            let next = i + 1 < messages.count ? messages[i + 1] : nil
            let groupEnd = !sameSender(m, next)
            let actionable = m.direction == .inbound && m.participantRole != .system && !m.isStreaming && groupEnd
            return Row(
                message: m,
                showsDeliveryState: m.direction == .outbound && (m.deliveryState == .failed || i == lastOutbound),
                showsActions: actionable,
                allowsFeedback: actionable && m.participantRole == .assistant
            )
        }
    }

    /// One entry of the drawn transcript: a message, or one of web's notices between them.
    enum Item: Identifiable, Equatable {
        case message(Row)
        /// Web's plain notice: centred, `text-primary-60 text-base` (`Messages.tsx:676-683`).
        case notice(id: UUID, text: String)
        /// Web's `ErrorMessage` (`ErrorMessage.tsx`): a `role="alert"` chip.
        case error(id: UUID, text: String)
        /// Web's sign-in card (`Authentication.tsx`), placed like a notice.
        case authentication(AuthenticationCard)

        var id: UUID {
            switch self {
            case .message(let row): row.id
            case .notice(let id, _), .error(let id, _): id
            case .authentication(let card): card.id
            }
        }
    }

    /// The fixed id of the "Conversation has ended" notice, which is derived from the contact's
    /// state rather than received, so there is only ever one.
    static let endedNoticeID = UUID(uuidString: "00000000-0000-0000-0000-00000000E0D0") ?? UUID()

    /// Rows with each notice placed after the message it followed. A notice whose message is not
    /// drawn — filtered as unrenderable — goes after the nearest drawn message before it; one whose
    /// message is not loaded at all is older than everything on screen, so it leads. Web appends
    /// "Conversation has ended" last (`conversation.ts:990-1003`). A connection problem is drawn
    /// after everything else and before that, where Android draws it.
    static func items(rows: [Row], messages: [Message], notices: [TranscriptNotice], isEnded: Bool,
                      authentication: AuthenticationCard? = nil, connectionProblem: Bool = false) -> [Item] {
        let drawn = Set(rows.map(\.id))
        // Resolve each anchor to a drawn row, walking back through the messages from it.
        var anchorFor: [UUID: UUID?] = [:]
        let position = Dictionary(messages.enumerated().map { ($1.clientMessageID, $0) }, uniquingKeysWith: { a, _ in a })
        func resolve(_ after: UUID?) -> UUID? {
            guard let after, let index = position[after] else { return nil }
            if let cached = anchorFor[after] { return cached }
            let found = messages[...index].last(where: { drawn.contains($0.clientMessageID) })?.clientMessageID
            anchorFor[after] = found
            return found
        }
        var byAnchor: [UUID: [Item]] = [:]
        var leading: [Item] = []
        let placed = notices.map { ($0.after, item(for: $0)) } + (authentication.map { [($0.after, Item.authentication($0))] } ?? [])
        for (after, item) in placed {
            if let anchor = resolve(after) { byAnchor[anchor, default: []].append(item) } else { leading.append(item) }
        }
        var items = leading
        for row in rows {
            items.append(.message(row))
            items.append(contentsOf: byAnchor[row.id] ?? [])
        }
        if connectionProblem { items.append(.error(id: connectionProblemID, text: TouchpointStrings.connectionLostNotice)) }
        if isEnded { items.append(.notice(id: endedNoticeID, text: TouchpointStrings.endedStatus)) }
        return items
    }

    /// The fixed id of the connection-problem row: there is only ever one.
    static let connectionProblemID = UUID(uuidString: "00000000-0000-0000-0000-0000000C0FF1") ?? UUID()

    private static func item(for notice: TranscriptNotice) -> Item {
        switch notice.kind {
        case .agentJoined: .notice(id: notice.id, text: TouchpointStrings.agentJoinedNotice)
        case .agentLeft: .notice(id: notice.id, text: TouchpointStrings.agentLeftNotice)
        case .connectionLost: .error(id: notice.id, text: TouchpointStrings.connectionLostNotice)
        }
    }

    /// Web's "bot": anything inbound that is not a person (`participantRole === "AGENT" ? "agent" : "bot"`).
    package static func isBot(_ m: Message) -> Bool {
        m.direction == .inbound && (m.participantRole == .assistant || m.participantRole == .system)
    }

    /// Same side *and* same role: an agent and a supervisor are different senders, so a barge-in is
    /// visible rather than folded into the agent's run.
    private static func sameSender(_ a: Message, _ b: Message?) -> Bool {
        guard let b else { return false }
        return a.direction == b.direction && a.participantRole == b.participantRole
    }
}

/// What the transcript view observes. Fed by `TouchpointSession.events`; owns no networking.
@MainActor
@Observable
final class ChatTranscriptModel {
    private(set) var messages: [Message] = []
    /// Announcements waiting to be spoken, oldest first. A **queue**, not a single slot: two
    /// messages arriving inside one SwiftUI update would collapse into one `onChange`, and the
    /// first would never be spoken.
    private(set) var pendingAnnouncements: [String] = []
    /// The next announcement, if any. The view posts it and calls `clearAnnouncement()`.
    var pendingAnnouncement: String? { pendingAnnouncements.first }
    private(set) var state: ContactState = .idle
    /// False until a first page says otherwise, so the control is not offered on an empty chat.
    private(set) var canLoadEarlier = false
    /// Set when a page could not be fetched, so the UI can say so rather than look inert.
    private(set) var pagingFailed = false
    /// Whether a first page has ever landed. An empty conversation is legitimately empty, so
    /// "no messages" cannot stand in for "never loaded".
    private(set) var initialLoaded = false
    private var loadingEarlier = false
    /// Bumped by `reset()`. Work suspended across an await checks it before touching state, so a
    /// page fetched for the previous session can never be prepended into the new one.
    private var resetGeneration: UInt = 0

    var rows: [TranscriptLayout.Row] { TranscriptLayout.rows(for: messages) }

    /// Web's notices as they arrived, deduplicated by id: a re-subscription replays them. A
    /// connection drop is not kept here: it is ``connectionProblem``.
    private(set) var notices: [TranscriptNotice] = []

    /// The connection dropped and has not recovered: "Connection lost. Please try again." at the
    /// foot of the transcript. **Deviation from web, matching Android:** web appends that failure
    /// to the transcript for good (`conversation.ts:944-952`), which after the SDK's automatic
    /// reconnect tells the customer to retry something that already recovered. Android's
    /// `TranscriptState.problem` clears when the contact is connected again, when a message gets
    /// through, or when the customer dismisses it; so does this.
    private(set) var connectionProblem = false

    /// The customer tapped the connection-problem row away.
    func dismissConnectionProblem() { connectionProblem = false }

    /// What the transcript draws: the rows, with the notices between them. See
    /// ``TranscriptLayout/items(rows:messages:notices:isEnded:authentication:connectionProblem:)``.
    var items: [TranscriptLayout.Item] {
        TranscriptLayout.items(rows: rows, messages: messages, notices: notices, isEnded: isEnded,
                               authentication: authenticationCard, connectionProblem: connectionProblem)
    }

    /// The sign-in card, when the flow asked for one (web's single authentication notice).
    private(set) var authenticationCard: AuthenticationCard?

    /// Web disables the input while sign-in is prompting or in progress (`App.tsx:275-288, 827`).
    var composerLocked: Bool { !isEnded && authenticationCard?.status.isPending == true }

    /// See ``TranscriptLayout/welcome(for:isEnded:hasNotices:)``. A sign-in card is a notice too.
    var welcome: [Message]? {
        TranscriptLayout.welcome(for: messages, isEnded: isEnded,
                                 hasNotices: !notices.isEmpty || authenticationCard != nil || connectionProblem)
    }

    /// See ``TranscriptLayout/choices(for:)``. Withdrawn while connecting and once the contact has
    /// ended — web hides the whole input block for both (`App.tsx:936-939`) — but offered while
    /// reconnecting, where a choice simply waits in the outbox as a typed message would.
    var choices: [InteractiveChoice] {
        switch state {
        case .connected, .reconnecting: TranscriptLayout.choices(for: messages)
        case .idle, .connecting, .suspended, .ended: []
        }
    }

    /// The message whose modalities still take a pick, under the same conditions as ``choices``.
    var answerableMessageID: UUID? {
        switch state {
        case .connected, .reconnecting: TranscriptLayout.answerableMessageID(in: messages)
        case .idle, .connecting, .suspended, .ended: nil
        }
    }

    var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    /// What sits at the foot of the transcript, where web's input block goes (`App.tsx:936-947`):
    /// nothing while the session is still connecting — web hides the whole block on its
    /// "Connecting…" interim message, and a field that cannot send yet invites a message that
    /// waits — a "Start new conversation" button once the contact has ended, and otherwise the
    /// choices and the field. Reconnecting keeps the field: that is what the outbox is for.
    enum Foot: Equatable { case none, startNew, composer }
    var foot: Foot {
        switch state {
        case .connecting: .none
        case .ended: .startNew
        case .idle, .connected, .reconnecting, .suspended: .composer
        }
    }

    /// The verdict the reader gave each assistant message, by client id. In the model rather than
    /// the row's `@State` because the actions move to a new row as a run grows, and a recycled or
    /// re-created row would otherwise forget what was already submitted.
    private(set) var feedback: [UUID: MessageFeedback] = [:]

    /// Records a verdict. Returns whether it changed — a second tap on the same thumb is ignored
    /// rather than submitted twice.
    @discardableResult
    func recordFeedback(_ message: Message, _ verdict: MessageFeedback) -> Bool {
        guard feedback[message.clientMessageID] != verdict else { return false }
        feedback[message.clientMessageID] = verdict
        return true
    }

    /// A status line for the states the interim message does not cover. `.connecting` moved to
    /// `interim`, because that is what web does with it: `CONNECTING_INTERIM_MESSAGE` is an interim
    /// message, not a separate status row (`conversation.ts:331-337`). Keeping it in both would
    /// draw it twice. Ended is a transcript notice, as web's "Conversation has ended" is.
    ///
    /// **Deviation:** web has no reconnecting line — it appends "Connection lost" and leaves it
    /// there. The SDK reconnects on its own, so it also says that it is doing so until it has.
    var statusLine: String? {
        switch state {
        case .reconnecting: TouchpointStrings.reconnectingStatus
        case .idle, .connecting, .connected, .suspended, .ended: nil
        }
    }

    /// Web's single `currentInterimMessage` slot: the last writer wins, exactly as there.
    /// - `thinking` when one of our messages goes out (`conversation.ts:1320,1388,1451,1499`);
    /// - `typing` on an agent typing event, lapsing after `typingLifetime` (`:954-967`);
    /// - `text` for a flow's interim message (`:1108-1109`);
    /// - cleared by any inbound message, and by the contact ending.
    enum InterimSlot: Equatable { case thinking, typing, text(String) }
    private(set) var interimSlot: InterimSlot?
    /// Web clears a typing indicator 5 s after the last typing event if no message follows.
    var typingLifetime: Duration = .seconds(5)
    private var typingExpiry: Task<Void, Never>?
    private var typingGeneration = 0

    /// Whether a human agent-side participant is on the contact. Web stops claiming the assistant
    /// is thinking once the contact is escalated (`escalated ? undefined : copy.thinking`), because
    /// a person may take minutes and a shimmering "Thinking…" would be a lie.
    private(set) var escalated = false

    /// The live participant set, kept so participant info can name an agent by their Connect
    /// display name where the wire carried one (OP-3). Empty until the first `participantsChanged`.
    private(set) var participantSet = ParticipantSet()

    /// The display name for a participant id, when the set carries one — used to name an agent under
    /// participant info. `nil` falls back to the role label.
    func participantName(_ id: String?) -> String? {
        guard let id else { return nil }
        let name = participantSet.participants.first { $0.id == id }?.displayName
        return name?.isEmpty == false ? name : nil
    }

    /// Web's `interimMessage`: one transient line at the end of the transcript, covering the
    /// assistant working and the session connecting (`conversation.ts:335-339`). It is the
    /// conversation's own status, so it outranks nothing — a contact that has *ended* says so
    /// instead, and `.reconnecting` is the transport talking rather than the assistant.
    ///
    /// "Thinking…" is withheld once a person has joined; "Typing…" is not — an agent typing is
    /// exactly what an escalated contact should show.
    var interim: String? {
        switch state {
        case .connecting: return TouchpointStrings.connectingStatus
        case .connected:
            switch interimSlot {
            case .thinking: return escalated ? nil : TouchpointStrings.thinkingStatus
            case .typing: return TouchpointStrings.typingStatus
            case .text(let words): return words
            case nil: return nil
            }
        case .idle, .reconnecting, .suspended, .ended: return nil
        }
    }

    private func setInterim(_ slot: InterimSlot?) {
        typingGeneration &+= 1
        typingExpiry?.cancel(); typingExpiry = nil
        interimSlot = slot
        guard slot == .typing else { return }
        let generation = typingGeneration
        let lifetime = typingLifetime
        typingExpiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard let self, !Task.isCancelled, self.typingGeneration == generation, self.interimSlot == .typing else { return }
            self.interimSlot = nil
        }
    }

    /// Composing while reconnecting is the point of the outbox, so only a contact that has ended —
    /// or has not started — disables the composer.
    var canSend: Bool {
        switch state {
        case .connected, .reconnecting, .connecting: true
        case .idle, .suspended, .ended: false
        }
    }

    /// Seed with the first (newest) page. `hasMore` decides whether "load earlier" is offered.
    func setInitial(_ messages: [Message], hasMore: Bool = false) {
        self.messages = messages
        // A first page belongs to one contact; the last contact's notices go with its messages.
        // Safe against loss: the view consumes events only after this, so nothing live is dropped.
        notices = []
        connectionProblem = false
        canLoadEarlier = hasMore
        pagingFailed = false
        initialLoaded = true
        highestSequenceSeen = messages.compactMap(\.sequence).max()
    }

    /// The first page could not be read. Reported the same way a later page failure is, so a blank
    /// transcript is never mistaken for an empty conversation.
    func initialLoadFailed() {
        pagingFailed = true
        // Not `initialLoaded`: the replayed backlog that follows is history and must not be read
        // aloud as news. But a failed read must not leave a VoiceOver user with a silent transcript
        // for the rest of the session either, so `.connected` — which in the stream separates the
        // replayed past from live traffic — lifts the gate (see `ingest`).
        announceOnceConnected = true
    }

    /// Set by a failed first load; cleared when the contact connects, at which point arrivals count
    /// as live and are announced even though no page ever landed.
    private var announceOnceConnected = false

    func ingest(_ event: ContactEvent) {
        switch event {
        case .messageReceived(let m):
            // Announce only a message that arrives as the **newest** row. Reconciliation and the
            // session's catch-up replay both deliver history through this case, and announcing a
            // backlog would read a finished conversation aloud on resume.
            let isNewestArrival = upsert(m)   // "newer than anything seen", not "last in the list"
            // `initialLoaded` is required: until a first page lands, the model cannot tell a
            // replayed backlog from a live arrival, and reading a finished conversation aloud is
            // worse than staying quiet until it can.
            if m.direction == .inbound, isNewestArrival, initialLoaded {
                pendingAnnouncements.append(Self.arrivalAnnouncement(m))
            }
            // Web sets its interim message when a send goes out and clears it on anything inbound.
            // Both are gated on this being live traffic rather than replayed history, for the same
            // reason the announcement above is: until a first page has landed the model cannot tell
            // a backlog from an arrival, and a resumed conversation whose last row happens to be
            // ours would otherwise shimmer "Thinking…" for ever at nobody.
            if isNewestArrival, initialLoaded {
                setInterim(m.direction == .outbound ? .thinking : nil)
            }
        case .deliveryStateChanged(let update):
            guard let i = messages.firstIndex(where: { $0.clientMessageID == update.clientMessageID }) else { return }
            // The sent transition carries the server's id and ordering, so an acked echo leaves the
            // unsequenced tail and lands in transcript order — matching what the store would return.
            replace(at: i, with: messages[i].applying(update))
            // A message getting through is the news that the problem has passed (Android).
            if update.state == .sent { connectionProblem = false }
        case .stateChanged(let s):
            // Web's notice is an alert like the others (`Announcements.tsx:87-98`). Gated like
            // messages: a surface opening on a contact that ended earlier is not hearing news.
            if case .ended = s, !isEnded, initialLoaded { pendingAnnouncements.append(TouchpointStrings.endedStatus) }
            state = s
            // Connected again: the drop is over (Android's `problem && s != Connected`).
            if s == .connected { connectionProblem = false }
            // A contact that is over is not waiting for anything.
            switch s {
            case .ended, .idle: setInterim(nil)
            case .connecting, .connected, .reconnecting, .suspended: break
            }
            // After a failed first load the connected transition is the boundary between the
            // replayed past and live traffic: from here, arrivals are news and are announced.
            if s == .connected, announceOnceConnected {
                announceOnceConnected = false
                initialLoaded = true
            }
        case .participantsChanged(let participants):
            escalated = participants.humanAgentPresent
            participantSet = participants
        case .notice(let notice):
            if notice.kind == .connectionLost {
                // Announced on each drop while live; a replayed drop the stream then shows was
                // recovered from is cleared again by the `.connected` that follows it.
                if !connectionProblem, initialLoaded { pendingAnnouncements.append(TouchpointStrings.connectionLostNotice) }
                connectionProblem = true
                return
            }
            guard !notices.contains(where: { $0.id == notice.id }) else { return }
            notices.append(notice)
            // Announced only once the model can tell live traffic from a replay, like messages.
            if initialLoaded, let text = Self.text(of: notice) { pendingAnnouncements.append(text) }
        case .authenticationChanged(let card):
            guard authenticationCard != card else { return }
            let changed = authenticationCard?.status != card.status || authenticationCard?.id != card.id
            authenticationCard = card
            // Web clears its interim line on every sign-in event (`conversation.ts:873`).
            setInterim(nil)
            if changed, initialLoaded { pendingAnnouncements.append(TouchpointStrings.authenticationStatus(card.status)) }
        case .remoteActivity(let activity):
            switch activity {
            case .typing: setInterim(.typing)
            case .interim(let words): setInterim(.text(words))
            }
        default:
            break
        }
    }

    private static func text(of notice: TranscriptNotice) -> String? {
        switch TranscriptLayout.items(rows: [], messages: [], notices: [notice], isEnded: false).first {
        case .notice(_, let text), .error(_, let text): text
        case .message, .authentication, nil: nil
        }
    }

    /// Drops the announcement just spoken, exposing the next one.
    func clearAnnouncement() { if !pendingAnnouncements.isEmpty { pendingAnnouncements.removeFirst() } }

    /// Drop everything: used when the view is handed a different session, so one contact's
    /// transcript never appears under another.
    func reset() {
        resetGeneration &+= 1
        initialLoaded = false
        messages = []
        pendingAnnouncements = []
        feedback = [:]
        announceOnceConnected = false
        setInterim(nil)
        notices = []
        connectionProblem = false
        authenticationCard = nil
        escalated = false
        participantSet = ParticipantSet()
        state = .idle
        canLoadEarlier = false
        pagingFailed = false
        highestSequenceSeen = nil
    }

    /// Page further back. `more` reports whether the server had an older page, so the button
    /// disappears exactly once rather than inviting a pointless request.
    func loadEarlier(_ fetch: () async throws -> ([Message], Bool)) async {
        guard canLoadEarlier, !loadingEarlier else { return }
        loadingEarlier = true
        let generation = resetGeneration        // a session swap mid-await must not land here
        defer { loadingEarlier = false }
        do {
            let (older, more) = try await fetch()
            guard generation == resetGeneration else { return }
            // De-duplicate: a page can overlap rows the live stream already delivered, and two rows
            // with one id would be an undefined `ForEach` identity.
            let known = Set(messages.map(\.clientMessageID))
            messages.insert(contentsOf: older.filter { !known.contains($0.clientMessageID) }, at: 0)
            canLoadEarlier = more
            pagingFailed = false
        } catch {
            guard generation == resetGeneration else { return }
            pagingFailed = true     // retryable, and now visible
        }
    }

    /// Insert in **transcript order**, not arrival order: reconciliation delivers historical rows
    /// after the live tail, and appending them would show them below newer messages — the opposite
    /// of what the store and a reloaded view show. Mirrors the store's rule: server sequence
    /// ascending, then unreconciled echoes pinned to the tail in arrival order.
    /// Highest server sequence this model has seen. The announcement test keys off this rather
    /// than tail position: an unacknowledged local echo is pinned to the tail, so a genuinely new
    /// agent reply inserts *before* it and would otherwise look like history.
    private var highestSequenceSeen: Int?

    /// Returns `true` when the row is newer than anything seen so far — the only case that is
    /// genuinely "a new message has arrived".
    @discardableResult
    private func upsert(_ m: Message) -> Bool {
        if let i = messages.firstIndex(where: { $0.clientMessageID == m.clientMessageID }) {
            replace(at: i, with: m)
            return false
        }
        insertInOrder(m)
        guard let seq = m.sequence else { return true }   // a fresh local echo is by definition new
        let isNew = highestSequenceSeen.map { seq > $0 } ?? true
        track(seq)
        return isNew
    }

    /// The single place `highestSequenceSeen` advances. Both the insert and the reorder path go
    /// through it: when our own echo acquires the server's sequence only on the reorder path, a
    /// model that tracked only inserts would later mistake reconciled history for a new message.
    private func track(_ sequence: Int?) {
        guard let sequence else { return }
        highestSequenceSeen = max(sequence, highestSequenceSeen ?? sequence)
    }

    /// The one update path for a row already on screen. A row whose sequence changed — typically an
    /// echo acquiring the server's, which moves it out of the unsequenced tail — is re-placed rather
    /// than updated where it sits, and the tracking happens here so no caller can forget it.
    private func replace(at index: Int, with m: Message) {
        if messages[index].sequence != m.sequence {
            messages.remove(at: index)
            insertInOrder(m)
            track(m.sequence)
        } else {
            messages[index] = m
        }
    }

    private func insertInOrder(_ m: Message) {
        guard let seq = m.sequence else {
            messages.append(m)          // an echo with no sequence yet belongs at the tail
            return
        }
        let at = messages.firstIndex { other in
            guard let otherSeq = other.sequence else { return true }   // echoes sort after sequenced rows
            return otherSeq > seq
        } ?? messages.endIndex
        messages.insert(m, at: at)
    }

    /// Role-aware: a supervisor barge-in is named, which is the point of breaking the group for it.
    /// Web's announcement for a response (`Announcements.tsx` `conversationAnnouncement`): its
    /// words, then a file's name and a guide, "Response received" when there is nothing to say, and
    /// how many options it offers (CV-3). Not the sender: web does not say who.
    nonisolated static func arrivalAnnouncement(_ m: Message) -> String {
        var parts: [String] = []
        let spoken = ChatMarkdown.spokenText(m.body)
        if !spoken.isEmpty { parts.append(spoken) }
        if let attachment = m.attachment { parts.append(attachment.name) }
        if m.interactive?.viewSummary != nil { parts.append(TouchpointStrings.guideDefaultTitle) }
        if parts.isEmpty { parts.append(TouchpointStrings.announcementReceived) }
        let count = m.interactive?.choices.count ?? 0
        if count > 0 { parts.append(TouchpointStrings.announcementChoices(count)) }
        return parts.joined(separator: " ")
    }

    static func senderName(_ m: Message) -> String {
        if m.direction == .outbound { return TouchpointStrings.youSenderLabel }
        return m.participantRole == .supervisor ? TouchpointStrings.supervisorSenderLabel : TouchpointStrings.agentSenderLabel
    }
}

private extension Message {
    /// `Message` is immutable by design; a delivery update rebuilds it from the stored shape.
    func applying(_ update: DeliveryUpdate) -> Message {
        Message(StoredMessage(clientMessageID: clientMessageID,
                              serverMessageID: (update.serverMessageID ?? serverMessageID)?.rawValue,
                              body: body, direction: direction, participantRole: participantRole,
                              participantID: participantID, sequence: update.sequence ?? sequence,
                              createdAt: createdAt,
                              deliveryState: update.state,
                              interactiveJSON: interactive.flatMap { try? JSONEncoder().encode($0) },
                              citationsJSON: citations.isEmpty ? nil : try? JSONEncoder().encode(citations),
                              isStreaming: isStreaming))
    }
}
