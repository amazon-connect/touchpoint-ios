import SwiftUI
import TouchpointLiveSync
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(SupportCoordinator.self) private var support
    @Environment(LiveSyncCoordinator.self) private var liveSync

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                if let consent = liveSync.consent {
                    LabeledContent("Sharing with the assistant", value: consent.decision == .granted ? "On" : "Off")
                    LiveSyncConsentRevokeButton(controller: consent)
                    Button("Ask me again") { Task { await consent.reset() } }
                } else {
                    Text("You'll be asked before anything is shared with the assistant.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
            } header: {
                Text("Live Sync")
            } footer: {
                Text("When on, a support agent on a call can see which screen you're on and suggest actions. Nothing is submitted without your confirmation. Live Sync arrives in a later release; the setting is stored now.")
            }

            Section {
                Toggle("Minimise chat when the assistant acts", isOn: $model.collapseOnAssistantAction)
                    .accessibilityIdentifier("settings.collapseOnAction")
                // The SDK's customization options, so a device test can see them.
                Toggle("Show names and avatars in chat", isOn: $model.showParticipantInfo)
                    .accessibilityIdentifier("settings.participantInfo")
                Toggle("Assistant replies in bubbles", isOn: $model.assistantBubble)
                    .accessibilityIdentifier("settings.assistantBubble")
                Toggle("Message times", isOn: $model.messageTimestamps)
                    .accessibilityIdentifier("settings.messageTimestamps")
                Toggle("Brand header", isOn: $model.brandHeader)
                    .accessibilityIdentifier("settings.brandHeader")
                // A partner bank's web chat configuration: its colours and font, light mode,
                // bordered bubbles, times, a close that asks before ending, a recording notice.
                Toggle("Partner bank look", isOn: $model.partnerLook)
                    .accessibilityIdentifier("settings.partnerLook")
            } header: {
                Text("Support chat")
            } footer: {
                Text("When the assistant changes the screen for you, the chat steps aside so you can see what changed. Reopen it from Support.")
            }

            Section {
                Button("Allow notifications for support replies") {
                    Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                }
                Text("Notifications requested this session: \(support.requestedNotifications)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.requestedNotifications")
            } header: {
                Text("Notifications")
            } footer: {
                Text("When support replies while the chat is minimised or you're elsewhere in the app, \(PartnerBrand.bankName) posts a notification. Replies that arrive while the app is closed are shown when you come back.")
            }

            #if DEBUG
            Section {
                Picker("Mode", selection: Binding(
                    get: { support.mode },
                    set: { newMode in Task { await support.setMode(newMode) } }
                )) {
                    ForEach(SupportCoordinator.Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Support mode (debug)")
            } footer: {
                Text("Offline needs nothing. Live reaches a real Amazon Connect agent through the demo credential backend.")
            }

            if support.mode == .live {
                Section {
                    TextField("Demo backend endpoint", text: Binding(
                        get: { support.liveSettings.endpoint }, set: { support.liveSettings.endpoint = $0 }))
                        .textContentType(.URL).keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Region", text: Binding(
                        get: { support.liveSettings.region }, set: { support.liveSettings.region = $0 }))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    if support.signIn == nil {
                    TextField("Access key ID", text: Binding(
                        get: { support.liveSettings.accessKeyID }, set: { support.liveSettings.accessKeyID = $0 }))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("Secret access key", text: Binding(
                        get: { support.liveSettings.secretAccessKey }, set: { support.liveSettings.secretAccessKey = $0 }))
                    SecureField("Session token", text: Binding(
                        get: { support.liveSettings.sessionToken }, set: { support.liveSettings.sessionToken = $0 }))
                    }
                    // Android's "voice by phone": Connect rings this number instead of an in-app call.
                    Toggle("Call us rings my phone", isOn: Binding(
                        get: { support.liveSettings.voiceByPhone }, set: { support.liveSettings.voiceByPhone = $0 }))
                        .accessibilityIdentifier("settings.voiceByPhone")
                    if support.liveSettings.voiceByPhone {
                        TextField("My phone number (+15555550100)", text: Binding(
                            get: { support.liveSettings.callbackNumber }, set: { support.liveSettings.callbackNumber = $0 }))
                            .keyboardType(.phonePad).textContentType(.telephoneNumber).autocorrectionDisabled()
                    }
                } header: {
                    Text("Live mode credentials (debug)")
                } footer: {
                    Text(support.signIn == nil
                         ? "Temporary IAM credentials for the demo backend, held in memory for this run only. A production app never carries IAM credentials; its own backend vends the participant token."
                         : "The signed-in demo user's credentials reach the demo backend only, and are held in memory for this run. A production app never carries AWS credentials; its own backend vends the participant token.")
                }
            }

            Section {
                @Bindable var liveSync = liveSync
                if liveSync.isConfigured {
                    TextField("Contact ID of the live call", text: $liveSync.contactID)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("livesync.contactID")
                    HStack {
                        Button("Connect") { liveSync.connect() }.disabled(liveSync.contactID.isEmpty)
                        Spacer()
                        Button("Disconnect") { liveSync.disconnect() }.disabled(liveSync.client == nil)
                    }
                    LabeledContent("State", value: "\(liveSync.state)")
                    LabeledContent("Dispatch", value: liveSync.dispatch == .enabled ? "enabled" : "suspended")
                    LabeledContent("Advertised", value: liveSync.aggregator.advertised.names.joined(separator: ", "))
                    ForEach(liveSync.log.suffix(12).reversed()) { entry in
                        Text("\(entry.at.formatted(date: .omitted, time: .standard))  \(entry.text)")
                            .font(.caption.monospaced()).lineLimit(3)
                    }
                } else {
                    Text(support.mode == .live
                         ? "Enter the Live Sync keys on the sign-in screen (Sign out, below) to enable."
                         : "Live Sync needs live mode (Support mode, above).")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
            } header: {
                Text("Live Sync (debug)")
            } footer: {
                Text("Chat and \"Call us\" bind Live Sync automatically from the contact they create — this field is only for a contact this app did not start, such as a call placed from the system dialer.")
            }

            Section {
                Button("Simulate relaunch") {
                    Task { await support.simulateRelaunch() }
                }
                .accessibilityIdentifier("settings.simulateRelaunch")
                if let error = support.lastError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Relaunch (debug)")
            } footer: {
                Text("Drops the session as if the app had been terminated — the contact is not ended — then reopens the conversation the way a tap on its notification would after a relaunch: from the device store, before any network call.")
            }
            #endif

            // The switches a design review's screen recording walks through. Each is an SDK option or a pace for the scripted agent.
            Section {
                Picker("Header brand", selection: $model.headerBrand) {
                    ForEach(AppModel.HeaderBrand.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("settings.headerBrand")
                Toggle("Acme logo as the assistant's avatar", isOn: $model.assistantAvatarIsLogo)
                    .accessibilityIdentifier("settings.assistantAvatar")
                Toggle("Square avatars", isOn: $model.squareAvatars)
                    .accessibilityIdentifier("settings.squareAvatars")
                Toggle("Slow motion", isOn: $model.slowMotion)
                    .accessibilityIdentifier("settings.slowMotion")
            } header: {
                Text("Design review")
            } footer: {
                Text("A wide logo shows whole only in the Mini chat window; Full and Half fit it into a square, as web does. Avatars show with \"Show names and avatars in chat\". Slow motion makes the offline agent take three times as long, so connecting, thinking and read receipts can be filmed.")
            }

            Section {
                Button("Sign out", role: .destructive) {
                    Task {
                        // The session first: a sign-in right after must not be undone by this one.
                        // Ending the contact needs only its participant token, not the backend.
                        #if DEBUG
                        await support.signOutUser()
                        #endif
                        await support.endChat()
                    }
                    model.signOut()
                }
                .accessibilityIdentifier("settings.signOut")
            }
        }
        .navigationTitle("Settings")
        .onAppear { support.currentScreen = "settings" }
    }
}
