import Foundation
import TouchpointCore

/// A `ContactTransport` with no network behind it: a scripted "agent" that joins, greets, and
/// replies to whatever the customer sends. The demo's default mode, so UI work and walkthroughs
/// never block on backend availability.
///
/// Honest about what it is: the replies are canned and say so. It does not pretend to be Connect.
actor ScriptedChatTransport: ContactTransport {
    private var continuation: AsyncStream<TransportEvent>.Continuation?
    private var buffered: [TransportEvent] = []
    private var replyTasks: [Task<Void, Never>] = []
    private var connected = false
    private let replyDelay: Duration
    /// The greeting keeps the default pace when `-scriptedReplyDelayMs` stretches replies for a UI
    /// test: a test that had to wait out a 30s greeting before it could type would be slower than
    /// the race it is trying to avoid, and the composer stays hidden until the greeting lands
    /// (web's rule). Slow motion (below) does stretch it — the welcome is one of the states a
    /// recording is filming — and is never on under `-uiTesting`.
    private let greetingDelay: Duration
    /// Settings → "Slow motion": every scripted wait is multiplied by this, so a screen recording
    /// catches the states that otherwise flash by (connecting, thinking, receipts). Read at each
    /// wait, so flipping the switch takes effect mid-conversation.
    private let pace: @Sendable () -> Double
    /// Bumped by `disconnect`, so a connect still holding for slow motion knows it was abandoned.
    private var disconnects = 0
    /// The contact the transport is connected for, and the ones a person has taken over. The
    /// transport outlives a contact (restart reuses it), so the handover is per contact.
    private var contactID = "unknown"
    private var handedOver: Set<String> = []
    private var agentPresent: Bool { handedOver.contains(contactID) }

    static let agentID = "agent-demo"
    static let agentName = "Sam"
    /// How long slow motion holds the SDK's connecting state, before the multiplier.
    static let connectHold: Duration = .milliseconds(700)

    init(replyDelay: Duration = .milliseconds(900), greetingDelay: Duration = .milliseconds(900),
         pace: @escaping @Sendable () -> Double = { 1 }) {
        self.replyDelay = replyDelay
        self.greetingDelay = greetingDelay
        self.pace = pace
    }

    /// A scripted wait at the current pace.
    private func paced(_ wait: Duration) -> Duration { wait * max(1, pace()) }

    /// A fresh stream per access, as `ConnectChatTransport` does: the coordinator's pump is
    /// cancelled on teardown, which finishes the stream it was reading, and a later `resume` or
    /// `startChat` subscribes anew. Events emitted before anyone subscribes are buffered.
    nonisolated var events: AsyncStream<TransportEvent> {
        AsyncStream { cont in Task { await self.attach(cont) } }
    }

    private func attach(_ cont: AsyncStream<TransportEvent>.Continuation) {
        continuation?.finish()
        continuation = cont
        subscriberGeneration &+= 1
        let generation = subscriberGeneration
        for e in buffered { cont.yield(e) }
        buffered.removeAll()
        cont.onTermination = { [weak self] _ in
            Task { await self?.subscriberWentAway(generation) }
        }
    }

    /// Clears the continuation only if the subscriber that terminated is still the current one —
    /// a newer one may already have replaced it.
    private func subscriberWentAway(_ generation: Int) {
        if generation == subscriberGeneration { continuation = nil }
    }
    private var subscriberGeneration = 0

    private func yield(_ e: TransportEvent) {
        // A subscriber that went away (the coordinator cancels its pump on teardown) leaves a
        // finished continuation behind, and `yield` into it reports `.terminated` rather than
        // failing. Buffer for the next subscriber instead: the next contact's `.connected` was
        // otherwise lost in the window before its pump attached, and the session sat in
        // `.connecting` for ever.
        if let continuation {
            if case .terminated = continuation.yield(e) {
                self.continuation = nil
                buffered.append(e)
            }
        } else {
            buffered.append(e)
        }
    }

    /// Server ordering. Wall-clock milliseconds plus a counter: monotonic within a run, and larger
    /// than anything a previous run stored for the same conversation, so a resumed transcript keeps
    /// its order. The store deduplicates on server id, so ids are unique per message, not per run.
    private var lastSequence = 0
    private func nextSequence() -> Int {
        lastSequence = max(lastSequence + 1, Int(Date().timeIntervalSince1970 * 1000))
        return lastSequence
    }

    func connect(credentials: any ExpiringCredentials) async throws {
        // Offline, connecting is instant and the SDK's loading state never shows. Slow motion
        // holds it long enough to film. The actor is free meanwhile, so a disconnect can land
        // during the hold; the connect then gives up rather than reviving a dropped contact.
        if pace() > 1 {
            let generation = disconnects
            try? await Task.sleep(for: paced(Self.connectHold))
            guard !Task.isCancelled, generation == disconnects else {
                throw TouchpointError.transportFailure("disconnected while connecting")
            }
        }
        connected = true
        let contactID = Self.contactID(of: credentials)
        self.contactID = contactID
        yield(.connected)
        yield(.participantJoined(Participant(id: Self.agentID, role: .assistant, displayName: Self.agentName)))
        // Greet once per contact. A resume (push tap, relaunch) connects again for the same
        // contact and a real agent does not say hello twice. The greeting's server id is derived
        // from the contact id, so even across a relaunch — where this process has no memory of
        // having greeted — the store's dedup on server id drops the repeat.
        if Self.markGreeted(contactID) {
            schedule(reply: Self.Reply("Hi, I'm \(Self.agentName) from \(PartnerBrand.bankName) support. This is the offline demo — my replies are scripted. How can I help?",
                                       choices: Self.topics),
                     serverID: "demo-greeting-\(contactID)", after: greetingDelay)
        }
    }

    /// What the greeting offers. Short, as the bank screens' pills are ("I forgot my password") —
    /// except one, long enough to wrap onto a second line on a phone, so a design review sees how a
    /// suggestion that does not fit is drawn.
    static let topics = ["Replacement card", longTopic, "Reset password", "Show me cards", signIn]
    static let longTopic = "I don't recognise a charge on my card statement from last week"
    /// The showcase flow's sign-in, offline: the card appears; with no identity provider behind it,
    /// only "Continue without signing in" leads anywhere.
    static let signIn = "Sign in"

    /// Read-modify-write under one lock: two connects for one contact must not both greet.
    private static func markGreeted(_ id: String) -> Bool {
        greetedLock.withLock { _greeted.insert(id).inserted }
    }
    nonisolated(unsafe) private static var _greeted: Set<String> = []
    private static let greetedLock = NSLock()
    private static func contactID(of c: any ExpiringCredentials) -> String {
        (c as? ChatContactCredentials)?.contactID ?? "unknown"
    }

    func send(_ message: OutboundMessage) async throws {
        guard connected else { throw TouchpointError.transportFailure("not connected") }
        let serverID = "demo-\(UUID().uuidString.lowercased())"
        yield(.messageDelivered(clientMessageID: message.clientMessageID, serverMessageID: serverID, sequence: nextSequence()))
        // Once a person has taken over, the person answers — not the script's assistant.
        if agentPresent {
            agentAnswers(message.body, serverID: serverID)
            return
        }
        // A modality pick (a card tapped, a date picked) is an interactive response with no body:
        // answer it by the slot it filled, as the showcase flow does.
        if let response = message.interactiveResponse,
           let slot = Self.slotFilled(by: response.rawJSON) {
            schedule(reply: Self.scriptedReply(toSlot: slot))
            return
        }
        if message.body == Self.signIn {
            schedule(reply: Self.Reply("Let's get you signed in."), then: .promptSignIn)
            return
        }
        schedule(reply: Self.scriptedReply(to: message.body))
    }

    private static func slotFilled(by raw: Data) -> String? {
        let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        let structured = ((((obj?["data"] as? [String: Any])?["modalityPayload"] as? [String: Any])?["request"] as? [String: Any])?["structured"] as? [String: Any])
        return ((structured?["slots"] as? [[String: Any]])?.first?["slotId"]) as? String
    }

    func disconnect() async {
        connected = false
        disconnects &+= 1
        for t in replyTasks { t.cancel() }
        replyTasks.removeAll()
        yield(.disconnected(error: nil))
    }

    // MARK: - Script

    /// One scripted turn: the words, and the replies it offers. Choices travel as a
    /// `TouchpointModality` message — the envelope a Connect flow built for Touchpoint sends — so
    /// the SDK reads them exactly as it would off the wire, and the offline demo exercises the same
    /// path a live contact does.
    struct Reply: Equatable {
        var text: String
        var choices: [String] = []
        /// The agent closes the contact after saying this — the offline demo's way to reach the
        /// ended state, which a live flow reaches by its own disconnect.
        var endsContact = false
        /// A person takes over after this: the offline demo's way to show the agent-joined notice
        /// and the agent typing, which a live contact gets from a transfer.
        var handsOver = false
        /// The socket drops after this, and the session's own reconnect brings it back: the
        /// offline demo's way to show "Connection lost".
        var dropsConnection = false
        /// Web's modalities, as JSON keyed by name — the shape the showcase flow sends.
        var modalitiesJSON: String?
        init(_ text: String, choices: [String] = [], endsContact: Bool = false, handsOver: Bool = false, dropsConnection: Bool = false,
             modalitiesJSON: String? = nil) {
            self.modalitiesJSON = modalitiesJSON
            self.text = text
            self.choices = choices
            self.endsContact = endsContact
            self.handsOver = handsOver
            self.dropsConnection = dropsConnection
        }

        var interactiveJSON: Data? {
            guard !choices.isEmpty || modalitiesJSON != nil else { return nil }
            var modalityPayload: [String: Any] = [
                "type": "message",
                "message": text,
                "choices": choices.map { ["choiceId": Self.slug($0), "choiceText": $0] },
            ]
            if let modalitiesJSON, let mods = try? JSONSerialization.jsonObject(with: Data(modalitiesJSON.utf8)) {
                modalityPayload["modalities"] = mods
            }
            let payload: [String: Any] = [
                "templateType": InteractiveContent.touchpointModalityTemplateType,
                "data": ["content": ["modalityPayload": modalityPayload]],
            ]
            guard let raw = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
            return try? JSONEncoder().encode(InteractiveContent(templateType: InteractiveContent.touchpointModalityTemplateType, rawJSON: raw))
        }

        private static func slug(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "-") }
    }

    enum FollowUp: Sendable { case promptSignIn }

    /// The status line a flow can send while it works on a turn (web's interim message), shown in
    /// place of "Thinking…" before each rich reply — the cards, the date input, the video.
    static let interimText = "One moment…"

    private func schedule(reply: Reply, serverID: String? = nil, after delay: Duration? = nil, then followUp: FollowUp? = nil) {
        let wait = paced(delay ?? replyDelay)
        let interim = reply.modalitiesJSON != nil ? Self.interimText : nil
        let task = Task { [weak self] in
            if let interim {
                try? await Task.sleep(for: wait * 0.4)
                guard !Task.isCancelled else { return }
                await self?.yieldIfConnected(.remoteActivity(.interim(interim)))
                try? await Task.sleep(for: wait * 0.6)
            } else {
                try? await Task.sleep(for: wait)
            }
            guard !Task.isCancelled else { return }
            await self?.deliver(reply, serverID: serverID)
            if followUp == .promptSignIn { await self?.promptSignIn() }
        }
        replyTasks.append(task)
    }

    // MARK: Sign-in, offline

    private var signInCard: UUID?

    private func promptSignIn() {
        guard connected else { return }
        let card = UUID()
        signInCard = card
        yield(.authenticationChanged(id: card, status: .prompt))
    }

    /// No identity provider offline: the card says so rather than opening a page that cannot load.
    func beginAuthentication() async throws -> AuthenticationRequest {
        if let card = signInCard { yield(.authenticationChanged(id: card, status: .failed)); signInCard = nil }
        throw TouchpointError.invalidConfiguration("offline demo: sign-in needs live mode")
    }

    func cancelAuthentication() async {
        guard let card = signInCard else { return }
        signInCard = nil
        yield(.authenticationChanged(id: card, status: .cancelled))
        schedule(reply: Reply("No problem, you can keep going without signing in.", choices: Self.topics))
    }

    private func deliver(_ reply: Reply, serverID: String?) {
        guard connected else { return }   // the hop onto the actor can land after a disconnect
        yield(.messageReceived(StoredMessage(
            clientMessageID: UUID(), serverMessageID: serverID ?? "demo-\(UUID().uuidString.lowercased())", body: reply.text,
            direction: .inbound, participantRole: .assistant, participantID: Self.agentID,
            sequence: nextSequence(), deliveryState: .delivered, interactiveJSON: reply.interactiveJSON)))
        if reply.endsContact { yield(.contactEnded(.agentEnded)) }
        if reply.handsOver { handOver() }
        if reply.dropsConnection { yield(.disconnected(error: nil)) }
    }

    static let humanAgentID = "agent-alex"
    static let humanAgentName = "Alex"

    /// The agent joins, types for a moment, then speaks — the order Connect delivers them in.
    private func handOver() {
        handedOver.insert(contactID)
        yield(.participantJoined(Participant(id: Self.humanAgentID, role: .agent, displayName: Self.humanAgentName)))
        let wait = paced(replyDelay)
        let beat = paced(.milliseconds(300))
        let task = Task { [weak self] in
            try? await Task.sleep(for: beat)
            guard !Task.isCancelled, let self else { return }
            await self.yieldIfConnected(.remoteActivity(.typing))
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self.agentSays("Hi, I'm \(Self.humanAgentName). I can see your conversation so far. How can I help?")
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            // Attachments exist only once a person is in the chat, as on Connect: the agent sends
            // the dispute form, and the composer's paperclip appears.
            await self.agentSays("I've attached our dispute form in case you'd like to fill it in.")
            await self.agentSendsForm()
        }
        replyTasks.append(task)
    }

    /// A person's reply to the customer. Their client acknowledges the message first — delivered,
    /// then read as they start typing — which is what Connect relays from an agent's workspace;
    /// the assistant sends no receipts, so the scripted assistant does not either.
    private func agentAnswers(_ body: String, serverID: String) {
        let wait = paced(replyDelay)
        let signsOff = Self.isWrapUp(body)
        let task = Task { [weak self] in
            try? await Task.sleep(for: wait * 0.3)
            guard !Task.isCancelled, let self else { return }
            await self.yieldIfConnected(.receipt(serverMessageID: serverID, kind: .delivered))
            try? await Task.sleep(for: wait * 0.4)
            guard !Task.isCancelled else { return }
            await self.yieldIfConnected(.receipt(serverMessageID: serverID, kind: .read))
            await self.yieldIfConnected(.remoteActivity(.typing))
            try? await Task.sleep(for: wait * 0.6)
            guard !Task.isCancelled else { return }
            if signsOff {
                await self.agentSignsOff(after: wait * 0.6)
            } else {
                await self.agentSays(Self.agentReply(to: body))
            }
        }
        replyTasks.append(task)
    }

    /// How a person ends a chat on Connect: a goodbye, they leave, and the contact ends — so the
    /// transcript shows "Agent has left" before the conversation closes.
    private func agentSignsOff(after beat: Duration) async {
        agentSays("Thanks for chatting with \(PartnerBrand.bankName), take care!")
        try? await Task.sleep(for: beat)
        guard connected, !Task.isCancelled else { return }
        handedOver.remove(contactID)
        yield(.participantLeft(id: Self.humanAgentID))
        try? await Task.sleep(for: beat)
        guard connected, !Task.isCancelled else { return }
        yield(.contactEnded(.agentEnded))
    }

    static func agentReply(to body: String) -> String {
        body.lowercased().contains("thank")
            ? "You're welcome. Anything else? Say goodbye whenever you're done."
            : "Thanks, I've added that to your case. Anything else? Say goodbye whenever you're done."
    }

    static let formAttachment = MessageAttachment(id: "demo-dispute-form", name: "\(PartnerBrand.bankShortName) dispute form.pdf", contentType: "application/pdf")

    private func agentSendsForm() {
        guard connected else { return }
        yield(.messageReceived(StoredMessage(
            clientMessageID: UUID(), serverMessageID: "demo-\(UUID().uuidString.lowercased())", body: "",
            direction: .inbound, participantRole: .agent, participantID: Self.humanAgentID,
            sequence: nextSequence(), deliveryState: .delivered,
            interactiveJSON: try? JSONEncoder().encode(InteractiveContent.attachment(Self.formAttachment)))))
    }

    /// Connect echoes the customer's file back as a row of its own; the agent acknowledges it.
    func sendAttachment(fileURL: URL) async throws {
        guard connected else { throw TouchpointError.transportFailure("not connected") }
        // The upload waits in the caller's task, which `disconnect` does not cancel: a restart
        // during it must not echo this file into the next contact.
        let generation = disconnects
        try await Task.sleep(for: paced(replyDelay))   // long enough to see the upload chip pulse
        guard generation == disconnects, connected else { throw TouchpointError.transportFailure("disconnected during upload") }
        let attachment = MessageAttachment(id: "demo-\(UUID().uuidString.lowercased())", name: fileURL.lastPathComponent,
                                           contentType: "application/octet-stream")
        yield(.messageReceived(StoredMessage(
            clientMessageID: UUID(), serverMessageID: attachment.id, body: "",
            direction: .outbound, participantRole: .customer, sequence: nextSequence(), deliveryState: .sent,
            interactiveJSON: try? JSONEncoder().encode(InteractiveContent.attachment(attachment)))))
        let wait = paced(replyDelay)
        let task = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.agentSays("Got it, thanks — I'll attach that to your case.")
        }
        replyTasks.append(task)
    }

    /// The offline form: a one-page PDF written on first use, so the pill opens in QuickLook.
    func attachmentURL(id: String) async throws -> URL {
        guard id == Self.formAttachment.id else { throw TouchpointError.invalidConfiguration("offline demo: no such file") }
        return try DemoDisputeForm.url()
    }

    private func yieldIfConnected(_ e: TransportEvent) { if connected { yield(e) } }

    private func agentSays(_ text: String) {
        guard connected else { return }
        yield(.messageReceived(StoredMessage(
            clientMessageID: UUID(), serverMessageID: "demo-\(UUID().uuidString.lowercased())", body: text,
            direction: .inbound, participantRole: .agent, participantID: Self.humanAgentID,
            sequence: nextSequence(), deliveryState: .delivered)))
    }

    /// The choice that closes the conversation, offered once the customer has been helped.
    static let wrapUp = "That's all"

    static func isWrapUp(_ body: String) -> Bool {
        let text = body.lowercased()
        return text.contains("that's all") || text.contains("goodbye") || text.contains("end chat")
    }

    /// The showcase flow's cards journey, offline: a carousel, then a card with a date input, then
    /// a custom summary with a video (`Scripts/env` "The showcase").
    static func scriptedReply(toSlot slot: String) -> Reply {
        switch slot {
        case "Charge":
            return Reply("When did you first notice this charge?", modalitiesJSON: #"""
            {"DefaultCard":{"id":"charge","rows":[{"label":"Merchant","value":"Harbour Coffee"},{"label":"Amount","value":"$6.75"},{"label":"Date","value":"Oct 3"}]},
             "DefaultDateInput":{"$saveAs":{"type":"slot","id":"Noticed"}}}
            """#)
        default:
            return Reply("Thanks. Here is your dispute, and a short video on what happens next.", modalitiesJSON: #"""
            {"AcmeDisputeSummary":{"merchant":"Harbour Coffee","amount":"$6.75","status":"Submitted for review"},
             "DefaultVideo":{"url":"https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"}}
            """#)
        }
    }

    static func scriptedReply(to body: String) -> Reply {
        let text = body.lowercased()
        if text.contains("cards") {
            return Reply("Here are your recent charges. Which one would you like to review?", modalitiesJSON: #"""
            {"DefaultCarousel":{"$saveAs":{"type":"slot","id":"Charge"},"cards":[
              {"id":"streamly","rows":[{"label":"Merchant","value":"Streamly"},{"label":"Amount","value":"$15.99"},{"label":"Date","value":"Oct 2"}]},
              {"id":"harbour","rows":[{"label":"Merchant","value":"Harbour Coffee"},{"label":"Amount","value":"$6.75"},{"label":"Date","value":"Oct 3"}]},
              {"id":"riverside","rows":[{"label":"Merchant","value":"Riverside Auto"},{"label":"Amount","value":"$240.18"},{"label":"Date","value":"Oct 6"}]}]}}
            """#)
        }
        if isWrapUp(text) {
            return Reply("Glad I could help. Have a good day!", endsContact: true)
        }
        if text.contains("drop the connection") {
            return Reply("Dropping the connection now — the app should reconnect on its own.", dropsConnection: true)
        }
        if text.contains("agent") || text.contains("a person") || text.contains("human") {
            return Reply("Of course. I'm connecting you to an agent now.", handsOver: true)
        }
        if text.contains("tracking") {
            return Reply("It's with the courier and due on Thursday. I'll text you when it's out for delivery.")
        }
        if text.contains("card") && (text.contains("replace") || text.contains("where") || text.contains("new")) {
            return Reply("Your replacement card was posted two business days ago and usually arrives within five. Would you like me to check the tracking?",
                         choices: ["Check tracking", "No thanks"])
        }
        if text.contains("charge") || text.contains("dispute") || text.contains("recogni") {
            // Deliberately markdown: the demo is the only place the SDK's markdown rendering is
            // visible, and the scripted agent is the only thing that speaks here. Exercises an
            // ordered list, bold and a link in one reply.
            return Reply("""
            Here's how to dispute a charge:

            1. Open the transaction
            2. Tap **Dispute**
            3. Tell us what happened

            Most disputes are resolved in **5 business days**. See the \
            [dispute policy](https://example.com/disputes) for what qualifies.
            """)
        }
        if text.contains("password") || text.contains("sign in") || text.contains("log in") {
            return Reply("To reset your password, go to Settings and choose Security. You'll need your access card number.")
        }
        if text.contains("thank") {
            return Reply("You're welcome. Anything else I can help with today?", choices: topics + [wrapUp])
        }
        return Reply("Thanks — I've noted that. (Scripted reply: in live mode a Connect agent answers here.)")
    }
}
