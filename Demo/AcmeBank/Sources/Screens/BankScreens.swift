import SwiftUI
import TouchpointChat
import TouchpointLiveSync
import TouchpointVoice

/// Signed out → sign-in. Signed in → the bank, with the support dock over every screen.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(SupportCoordinator.self) private var support
    @Environment(LiveSyncCoordinator.self) private var liveSync
    @Environment(VoiceCoordinator.self) private var voice

    var body: some View {
        @Bindable var model = model
        if model.isSignedIn {
            // Collapsed, the launcher is a bottom safe-area inset rather than an overlay, so every
            // screen's content stops above it and stays navigable. Open, the chat covers the whole
            // screen, as web's does on a phone — see `SupportDock`.
            NavigationStack(path: $model.path) {
                AccountsView()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !model.supportExpanded {
                    SupportDock.Launcher(isExpanded: $model.supportExpanded)
                        .transition(.opacity)
                }
            }
            // In a call, the rail floats over every screen and can be dragged anywhere (web's voice
            // mini). The one exception to "the launcher is a safe-area inset": a draggable widget
            // needs the whole screen to move in. Under the chat window, which covers it when open.
            // Hidden rather than removed while the chat is open, so it comes back where the
            // customer left it.
            .overlay {
                SupportDock.CallRail(isExpanded: $model.supportExpanded)
                    .opacity(model.supportExpanded ? 0 : 1)
                    .allowsHitTesting(!model.supportExpanded)
                    .accessibilityHidden(model.supportExpanded)
            }
            // The SDK's chat window: full, half (the default while Live Sync drives the screens, so
            // what it changes stays in view) or mini, as the customer picks in the chat's settings.
            .touchpointChatWindow(isPresented: model.supportExpanded,
                                  mode: model.chatWindowMode(liveSyncActive: liveSync.isActive)) {
                SupportDock(isExpanded: $model.supportExpanded)
            }
            // When the assistant acts on the app, step aside so the customer sees what changed — an
            // SDK option, on here and switchable in Settings.
            .touchpointCollapsesOnAssistantAction($model.supportExpanded, aggregator: liveSync.aggregator,
                                                  isEnabled: model.collapseOnAssistantAction)
            // The SDK's full-screen call, opened from the rail's menu. It adopts the running
            // call; Minimise goes back to the rail without hanging up, the red close ends the call.
            .fullScreenCover(isPresented: $model.voiceFullScreen) {
                if let call = voice.call {
                    TouchpointVoiceView(call: call,
                                        onClose: { model.voiceFullScreen = false },
                                        onMinimise: { model.voiceFullScreen = false })
                        .touchpointTheme(model.chatTheme)
                        // The partner look holds the chat light; the call it places is the same chat.
                        .preferredColorScheme(model.partnerLook ? .light : nil)
                }
            }
            .onChange(of: voice.isInCall) { _, inCall in if !inCall { model.voiceFullScreen = false } }
            // The visible tree *is* the Live Sync context. Everything declared below
            // with `.touchpointAction` is aggregated here; no screen calls `sendContext`.
            .touchpointLiveSync(liveSync.aggregator)
            // The SDK's consent sheet, shown once per deployment before anything is posted.
            .modifier(ConsentIfPresent(controller: liveSync.consent))
            // The SDK's Allow / Cancel prompt for actions marked `confirmationRequired`.
            .modifier(ConfirmationIfPresent(client: liveSync.client))
            #if DEBUG
            .overlay(alignment: .topTrailing) {
                // Over the bank screens, where it shows the advertised set change; not over a
                // full-screen chat, whose header it would cover.
                if liveSync.client != nil,
                   !(model.supportExpanded && model.chatWindowMode(liveSyncActive: liveSync.isActive) == .full) {
                    TouchpointLiveSyncOverlay(aggregator: liveSync.aggregator, client: liveSync.client)
                        .padding(.horizontal)
                }
            }
            #endif
        } else {
            SignInView()
        }
    }
}

/// `.liveSyncConsent` needs a controller; there is none until a client exists.
private struct ConsentIfPresent: ViewModifier {
    let controller: LiveSyncConsentController?
    func body(content: Content) -> some View {
        if let controller { content.liveSyncConsent(controller) } else { content }
    }
}

/// `.touchpointActionConfirmation` needs a client; there is none until a call binds one.
private struct ConfirmationIfPresent: ViewModifier {
    let client: LiveSyncClient?
    func body(content: Content) -> some View {
        if let client { content.touchpointActionConfirmation(client) } else { content }
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(SupportCoordinator.self) private var support
    @Environment(LiveSyncCoordinator.self) private var liveSync
    @State private var username = ""
    @State private var password = ""
    @State private var deploymentKey = ""
    @State private var apiKey = ""
    @State private var showKeys = false
    @State private var signingIn = false
    @State private var failure: String?

    /// Live mode on the backend's identity pool signs a demo user in for real (`DemoSignIn`), which
    /// is where the app's credentials for the demo backend come from. Otherwise any username and
    /// password work: the screen is a prop.
    private var realSignIn: Bool {
        #if DEBUG
        support.requiresSignIn
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 8) {
                if let mark = PartnerBrand.signInMark {
                    mark.resizable().scaledToFit().frame(width: 64, height: 64).accessibilityHidden(true)
                } else {
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Palette.brand)
                        .accessibilityHidden(true)
                }
                Text(PartnerBrand.bankName)
                    .font(.largeTitle.bold())
                Text("Demo — all data is synthetic")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
            VStack(spacing: 12) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background(Palette.field, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("signin.username")
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .padding()
                    .background(Palette.field, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("signin.password")
                // With a real sign-in the demo backend supplies the keys, so there is nothing to type.
                if asksForKeys, !realSignIn {
                    DisclosureGroup(isExpanded: $showKeys) {
                        VStack(spacing: 12) {
                            TextField("Deployment key", text: $deploymentKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding()
                                .background(Palette.field, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityIdentifier("signin.deploymentKey")
                            SecureField("API key", text: $apiKey)
                                .padding()
                                .background(Palette.field, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityIdentifier("signin.apiKey")
                            Text("From the Live Sync application's Settings → Access. Kept in this device's keychain.")
                                .font(.footnote)
                                .foregroundStyle(Palette.muted)
                            #if DEBUG
                            if liveSync.isConfigured {
                                Button("Forget these keys", role: .destructive) {
                                    Task { await liveSync.forgetKeys(); deploymentKey = ""; apiKey = "" }
                                }
                                .font(.footnote)
                                .accessibilityIdentifier("signin.forgetKeys")
                            }
                            #endif
                        }
                        .padding(.top, 8)
                    } label: {
                        Text(liveSync.isConfigured ? "Live Sync keys (saved)" : "Live Sync keys")
                            .font(.subheadline)
                    }
                    .accessibilityIdentifier("signin.keys")
                }
            }
            .padding(.horizontal)
            Button {
                submit()
            } label: {
                Group {
                    if signingIn { ProgressView().tint(.white) } else { Text("Sign in") }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .disabled(signingIn || !keysReady || (realSignIn && (username.isEmpty || password.isEmpty)))
            .padding(.horizontal)
            .accessibilityIdentifier("signin.submit")
            .accessibilityHint(realSignIn ? "Signs in with your demo account" : "Any username and password work in the demo")
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Palette.negative)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .accessibilityIdentifier("signin.error")
            } else if realSignIn {
                Text("Sign in with your demo account.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            Spacer()
        }
        .background(Color(.systemBackground))
        // Pre-fill once the saved keys have loaded (the launch task reads the keychain), never
        // before: empty fields over keys that hadn't loaded yet read as "no keys".
        .task(id: keysReady) {
            #if DEBUG
            guard keysReady else { return }
            deploymentKey = liveSync.deploymentKey
            apiKey = liveSync.apiKey
            showKeys = asksForKeys && !liveSync.isConfigured
            #endif
        }
    }

    private var keysReady: Bool {
        #if DEBUG
        liveSync.keysLoaded
        #else
        true
        #endif
    }

    /// Live mode asks for the Live Sync keys here rather than reading them from the package or the
    /// scheme. The live UI tests pass theirs in the launch environment, so they're not asked.
    private var asksForKeys: Bool {
        #if DEBUG
        support.mode == .live && !liveSync.keysFromEnvironment
        #else
        false
        #endif
    }

    private func submit() {
        #if DEBUG
        signingIn = true
        failure = nil
        Task {
            defer { signingIn = false }
            do {
                if asksForKeys, !realSignIn {
                    // Typed keys win; empty fields keep the saved ones.
                    try await liveSync.setKeys(deploymentKey: deploymentKey, apiKey: apiKey)
                }
                if realSignIn {
                    try await support.signInUser(username: username.trimmingCharacters(in: .whitespaces), password: password)
                    // Ask the backend for the keys as the signed-in user, each sign-in so a rotated key
                    // is picked up, and keep them like typed ones.
                    if asksForKeys {
                        do {
                            let keys = try await support.liveSyncKeysFromBackend()
                            try await liveSync.setKeys(deploymentKey: keys.deploymentKey, apiKey: keys.apiKey)
                        } catch {
                            // Sign-in still succeeds: chat works without Live Sync, and saved keys stay.
                            failure = nil
                        }
                    }
                }
                password = ""
                model.signIn()
            } catch let error as LocalizedError {
                failure = error.errorDescription ?? "Sign-in failed."
            } catch {
                // The keychain write for the Live Sync keys is the one step that throws otherwise.
                failure = "Couldn't save the Live Sync keys on this device. Try again."
            }
        }
        #else
        model.signIn()
        #endif
    }
}

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @Environment(SupportCoordinator.self) private var support

    var body: some View {
        List {
            Section {
                ForEach(model.accounts) { account in
                    NavigationLink(value: account) {
                        AccountRow(account: account)
                    }
                    .accessibilityIdentifier("account.\(account.id)")
                }
            } header: {
                Text("Good day, \(DemoData.customerName)")
                    .textCase(nil)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
        }
        .navigationTitle("Accounts")
        .navigationDestination(for: Account.self) { account in
            TransactionsView(account: account)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("nav.settings")
            }
        }
        .onAppear { support.currentScreen = "accounts" }
        .touchpointAction(DisputeActions.openAccount, description: DisputeActions.description(of: DisputeActions.openAccount)) {
            (p: OpenAccount) in model.openAccount(p)
        }
        .touchpointScope("accounts")
    }
}

struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.nickname).font(.body.weight(.medium))
                Text("\(account.kindLabel) \(account.maskedNumber)")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            Text(account.balance, format: .currency(code: "CAD"))
                .font(.body.monospacedDigit())
                .foregroundStyle(account.balance < 0 ? Palette.negative : .primary)
                // I3: balances are blacked out of a screen share; the agent sees the list, not the money.
                .touchpointScreenShareRedacted()
        }
        .accessibilityElement(children: .combine)
    }
}

struct TransactionsView: View {
    @Environment(SupportCoordinator.self) private var support
    @Environment(AppModel.self) private var model
    let account: Account

    private var shown: [Transaction] {
        let all = account.transactions.sorted { $0.date > $1.date }
        guard let f = model.transactionFilter else { return all }
        return f.apply(to: all)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Balance")
                    Spacer()
                    Text(account.balance, format: .currency(code: "CAD")).bold().monospacedDigit()
                        .touchpointScreenShareRedacted()
                }
                .accessibilityElement(children: .combine)
            }
            Section {
                ForEach(shown) { tx in
                    NavigationLink(value: tx) {
                        TransactionRow(transaction: tx)
                    }
                    .listRowBackground(model.transactionFilter != nil ? Palette.brand.opacity(0.15) : nil)   // the match highlights
                    .accessibilityIdentifier("transaction.\(tx.id)")
                }
            } header: {
                Text(model.transactionFilter == nil ? "Recent activity" : "Matching the charge you described")
            } footer: {
                if model.transactionFilter != nil {
                    Button("Show all") { model.transactionFilter = nil }
                }
            }
        }
        .navigationTitle(account.nickname)
        .navigationDestination(for: Transaction.self) { tx in
            TransactionDetailView(transaction: tx, account: account)
        }
        .onAppear { support.currentScreen = "transactions:\(account.kind.rawValue)"; model.visibleAccount = account }
        .touchpointAction(DisputeActions.filterTransactions, description: DisputeActions.description(of: DisputeActions.filterTransactions)) {
            (p: FilterTransactions) in model.filterTransactions(p)
        }
        .touchpointAction(DisputeActions.selectTransaction, description: DisputeActions.description(of: DisputeActions.selectTransaction)) {
            (p: SelectTransaction) in model.selectTransaction(p)
        }
        .touchpointScope("transactions")
    }
}

struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transaction.symbolName)
                .frame(width: 28)
                .foregroundStyle(Palette.brand)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant)
                Text(transaction.date, format: .dateTime.weekday(.wide).day().month())
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            Text(transaction.amount, format: .currency(code: "CAD"))
                .monospacedDigit()
                .foregroundStyle(transaction.amount > 0 ? Palette.positive : .primary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TransactionDetailView: View {
    @Environment(SupportCoordinator.self) private var support
    @Environment(AppModel.self) private var model
    let transaction: Transaction
    let account: Account

    var body: some View {
        List {
            Section {
                LabeledContent("Merchant", value: transaction.merchant)
                LabeledContent("Amount") { Text(transaction.amount, format: .currency(code: "CAD")).monospacedDigit() }
                LabeledContent("Date") { Text(transaction.date, format: .dateTime.weekday(.wide).day().month().year()) }
                LabeledContent("Account", value: "\(account.nickname) \(account.maskedNumber)")
                LabeledContent("Category", value: transaction.category.rawValue.capitalized)
            }
            if transaction.amount < 0 {
                Section {
                    Button("Dispute this transaction") { model.disputeOpen = true }
                        .accessibilityIdentifier("transaction.dispute")
                } footer: {
                    Text("Disputes are reviewed within five business days. Nothing is submitted until you confirm.")
                }
            }
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        // Pushed, not a sheet: the design docks the assistant on every screen, and a sheet would
        // cover the support panel exactly when the assistant is filling the form.
        .navigationDestination(isPresented: Binding(get: { model.disputeOpen }, set: { model.disputeOpen = $0 })) {
            DisputeFormView(transaction: transaction)
        }
        .onAppear { support.currentScreen = "transaction-detail"; model.disputeOpen = false }
        .touchpointAction(DisputeActions.startDispute, description: DisputeActions.description(of: DisputeActions.startDispute),
                          // Opening the dispute form is reversible (Submit stays the customer's
                          // tap), so it needs no confirmation. It stays off for now: an action marked
                          // `confirmationRequired` is advertised but never delivered by the Live Sync
                          // engine today, so with `true` the dispute screen would never open.
                          confirmationRequired: false) {
            (p: StartDispute) in model.startDispute(p)
        }
        .touchpointScope("dispute")
    }
}

/// The dispute form. Live Sync can fill it in, and it keeps **Submit** as
/// the one thing no action can press (plan: "the most important part of the demo").
struct DisputeFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(SupportCoordinator.self) private var support
    let transaction: Transaction
    @State private var reason: Reason = .unrecognised
    @State private var cardPossession: CardPossession = .haveCard
    @State private var authorized = false
    @State private var details = ""
    @State private var submitted = false

    enum Reason: String, CaseIterable, Identifiable {
        case unrecognised = "I don't recognise this charge"
        case duplicate = "I was charged twice"
        case wrongAmount = "The amount is wrong"
        case cancelled = "I cancelled this service"
        case notReceived = "I didn't receive what I paid for"
        case other = "Something else"
        var id: String { rawValue }
        /// The contract's enum value for this reason.
        init?(contract: String) {
            switch contract {
            case "not_recognized": self = .unrecognised
            case "duplicate": self = .duplicate
            case "incorrect_amount": self = .wrongAmount
            case "cancelled_service": self = .cancelled
            case "not_received": self = .notReceived
            case "other": self = .other
            default: return nil
            }
        }
    }

    enum CardPossession: String, CaseIterable, Identifiable {
        case haveCard = "I still have my card"
        case lost = "My card is lost"
        case stolen = "My card was stolen"
        var id: String { rawValue }
        init?(contract: String) {
            switch contract {
            case "have_card": self = .haveCard
            case "lost": self = .lost
            case "stolen": self = .stolen
            default: return nil
            }
        }
    }

    var body: some View {
        Form {
            Section("Transaction") {
                LabeledContent("Merchant", value: transaction.merchant)
                LabeledContent("Amount") { Text(transaction.amount, format: .currency(code: "CAD")) }
            }
            Section("Reason") {
                Picker("Reason", selection: $reason) {
                    ForEach(Reason.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Your card") {
                Picker("Card", selection: $cardPossession) {
                    ForEach(CardPossession.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Toggle("I authorised this charge", isOn: $authorized)
                TextField("Anything else we should know?", text: $details, axis: .vertical)
                    .lineLimit(3...6)
            }
            Section {
                Button("Submit dispute") {
                    submitted = true
                    UIAccessibility.post(notification: .announcement, argument: "Dispute submitted")
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                .disabled(submitted)
                .accessibilityIdentifier("dispute.submit")
            } footer: {
                Text(submitted
                     ? "Submitted. Reference ACME-\(transaction.id.uppercased())-DEMO. We'll be in touch within five business days."
                     : "Review the details above, then tap Submit. Support can help you fill this in but cannot submit it for you.")
            }
        }
        // Room below the footer, so the submission reference scrolls clear of the floating Support button.
        .contentMargins(.bottom, 96, for: .scrollContent)
        .navigationTitle("Dispute")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { support.currentScreen = "dispute"; applyFromAssistant() }
        // The one action on this screen fills fields. There is deliberately no action that submits:
        // Submit is the customer's alone, and NoSubmitActionTests fails if anyone adds one.
        .touchpointAction(DisputeActions.setDisputeDetails, description: DisputeActions.description(of: DisputeActions.setDisputeDetails)) {
            (p: SetDisputeDetails) in model.setDisputeDetails(p)
        }
        .touchpointScope("dispute")   // outside the action, so it tags it
        // The assistant fills fields one at a time as the customer explains; the form follows.
        .onChange(of: model.disputeReason) { _, _ in applyFromAssistant() }
        .onChange(of: model.disputeCardPossession) { _, _ in applyFromAssistant() }
        .onChange(of: model.disputeAuthorized) { _, _ in applyFromAssistant() }
        .onChange(of: model.disputeDetails) { _, _ in applyFromAssistant() }
    }

    private func applyFromAssistant() {
        if let r = model.disputeReason, let mapped = Reason(contract: r) { reason = mapped }
        if let c = model.disputeCardPossession, let mapped = CardPossession(contract: c) { cardPossession = mapped }
        if let a = model.disputeAuthorized { authorized = a }
        if let d = model.disputeDetails { details = d }
    }
}
