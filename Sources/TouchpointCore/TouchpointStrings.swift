import Foundation

/// Typed access to the SDK's String Catalog. `package`, not `public`: the modality modules need
/// it, hosts do not, and every public symbol becomes immutable at publication.
///
/// Original note: (`Resources/Localizable.xcstrings`).
///
/// Every user-facing string the SDK renders goes through here so localisation is a
/// catalog edit, never a code change. Keys are stable identifiers, not English sentences.
package enum TouchpointStrings {
    /// Placeholder entry proving the catalog is bundled and resolvable.
    package static var placeholder: String { key("touchpoint.placeholder") }

    // MARK: Chat UI

    package static var composerPlaceholder: String { key("touchpoint.composer.placeholder") }
    package static var sendButtonLabel: String { key("touchpoint.composer.send") }
    package static var voiceModeLabel: String { key("touchpoint.composer.voiceMode") }
    package static var transcriptLabel: String { key("touchpoint.transcript.label") }
    package static var agentSenderLabel: String { key("touchpoint.sender.agent") }
    /// Default assistant name under participant info (OP-3); web/Android default "AI".
    package static var assistantSenderLabel: String { key("touchpoint.sender.assistant") }
    package static var youSenderLabel: String { key("touchpoint.sender.you") }
    package static var statusSending: String { key("touchpoint.status.sending") }
    package static var statusSent: String { key("touchpoint.status.sent") }
    package static var statusDelivered: String { key("touchpoint.status.delivered") }
    package static var statusRead: String { key("touchpoint.status.read") }
    package static var statusFailed: String { key("touchpoint.status.failed") }
    package static var retryButtonLabel: String { key("touchpoint.action.retry") }
    package static var loadEarlierLabel: String { key("touchpoint.action.loadEarlier") }
    package static var loadFailedMessage: String { key("touchpoint.transcript.loadFailed") }
    package static var closeButtonLabel: String { key("touchpoint.action.close") }
    package static var minimiseButtonLabel: String { key("touchpoint.action.minimise") }
    package static var minimiseCallHint: String { key("touchpoint.call.action.minimiseHint") }
    package static var connectingStatus: String { key("touchpoint.state.connecting") }
    package static var thinkingStatus: String { key("touchpoint.state.thinking") }
    package static var typingStatus: String { key("touchpoint.state.typing") }
    package static var reconnectingStatus: String { key("touchpoint.state.reconnecting") }
    package static var endedStatus: String { key("touchpoint.state.ended") }
    package static var agentJoinedNotice: String { key("touchpoint.notice.agentJoined") }
    package static var agentLeftNotice: String { key("touchpoint.notice.agentLeft") }
    package static var connectionLostNotice: String { key("touchpoint.notice.connectionLost") }
    package static var dismissHint: String { key("touchpoint.problem.dismiss") }
    package static var supervisorSenderLabel: String { key("touchpoint.sender.supervisor") }
    package static var sendFailedAnnouncement: String { key("touchpoint.composer.sendFailed") }

    /// VoiceOver label for a bubble: sender and text, ordered by the catalog so a locale can swap them.
    package static func bubbleLabel(sender: String, body: String) -> String {
        String(format: key("touchpoint.transcript.bubbleLabel"), sender, body)
    }


    // MARK: Chat design

    package static var copyButtonLabel: String { key("touchpoint.action.copy") }
    package static var copiedAnnouncement: String { key("touchpoint.announcement.copied") }
    package static var thumbsUpLabel: String { key("touchpoint.action.thumbsUp") }
    package static var thumbsDownLabel: String { key("touchpoint.action.thumbsDown") }
    package static var restartButtonLabel: String { key("touchpoint.action.restart") }
    package static var startNewConversationLabel: String { key("touchpoint.action.startNewConversation") }
    package static var settingsButtonLabel: String { key("touchpoint.action.settings") }
    package static var closeSettingsButtonLabel: String { key("touchpoint.action.closeSettings") }
    package static var settingsRestartLabel: String { key("touchpoint.settings.restart") }
    package static var settingsDownloadLabel: String { key("touchpoint.settings.download") }
    package static var settingsEndLabel: String { key("touchpoint.settings.end") }
    package static var settingsEndConfirmTitle: String { key("touchpoint.settings.endConfirmTitle") }
    package static var settingsEndConfirmBody: String { key("touchpoint.settings.endConfirmBody") }
    package static var settingsCancelLabel: String { key("touchpoint.settings.cancel") }
    package static var settingsWindowModeLabel: String { key("touchpoint.settings.windowMode") }
    package static var settingsModeFull: String { key("touchpoint.settings.mode.full") }
    package static var settingsModeHalf: String { key("touchpoint.settings.mode.half") }
    package static var settingsModeMini: String { key("touchpoint.settings.mode.mini") }
    package static var transcriptTitle: String { key("touchpoint.settings.transcriptTitle") }
    package static var liveSyncCollapsedAnnouncement: String { key("touchpoint.livesync.collapsed") }
    /// Confirmation prompt for a `confirmationRequired` Live Sync action.
    package static var liveSyncConfirmTitle: String { key("touchpoint.livesync.confirm.title") }
    package static var liveSyncConfirmAllow: String { key("touchpoint.livesync.confirm.allow") }
    package static var liveSyncConfirmCancel: String { key("touchpoint.livesync.confirm.cancel") }
    package static var modalityDateLabel: String { key("touchpoint.modality.date") }
    package static var modalityDateSubmitLabel: String { key("touchpoint.modality.dateSubmit") }
    package static var modalityPlayVideoLabel: String { key("touchpoint.modality.playVideo") }
    package static var guideDefaultTitle: String { key("touchpoint.guide.title") }
    package static var guideUnsupported: String { key("touchpoint.guide.unsupported") }
    package static var guideLabel: String { key("touchpoint.guide.label") }
    package static var guideLoading: String { key("touchpoint.guide.loading") }
    package static var guideError: String { key("touchpoint.guide.error") }
    package static var guideClose: String { key("touchpoint.guide.close") }
    package static var guideOpenHint: String { key("touchpoint.guide.open") }
    package static var guideStatusNotStarted: String { key("touchpoint.guide.status.notStarted") }
    package static var guideStatusInProgress: String { key("touchpoint.guide.status.inProgress") }
    package static var guideStatusComplete: String { key("touchpoint.guide.status.complete") }
    package static var microphoneButtonLabel: String { key("touchpoint.action.microphone") }

    // MARK: Consent and permissions

    package static var consentTitle: String { key("touchpoint.consent.title") }
    package static func consentBody(data: String, recipient: String) -> String {
        String(format: key("touchpoint.consent.body"), data, recipient)
    }
    package static var consentAllow: String { key("touchpoint.consent.allow") }
    package static var consentDecline: String { key("touchpoint.consent.decline") }
    package static var consentPrivacyPolicy: String { key("touchpoint.consent.privacyPolicy") }
    package static var consentRevoke: String { key("touchpoint.consent.revoke") }
    package static var consentRevokedAnnouncement: String { key("touchpoint.consent.revokedAnnouncement") }
    package static func permissionTitle(_ p: Permission) -> String { key("touchpoint.permission.\(p.rawValue).title") }
    package static func permissionBody(_ p: Permission) -> String { key("touchpoint.permission.\(p.rawValue).body") }
    package static var openSettings: String { key("touchpoint.permission.openSettings") }
    package static var continueWithChat: String { key("touchpoint.permission.continueWithChat") }

    // MARK: Voice

    package static var callConnecting: String { key("touchpoint.call.state.connecting") }
    package static var callConnected: String { key("touchpoint.call.state.connected") }
    package static var callReconnecting: String { key("touchpoint.call.state.reconnecting") }
    package static var callInterrupted: String { key("touchpoint.call.state.interrupted") }
    package static var callResumed: String { key("touchpoint.call.state.resumed") }
    package static var callEnded: String { key("touchpoint.call.state.ended") }
    package static var callFailed: String { key("touchpoint.call.state.failed") }
    package static var callMuted: String { key("touchpoint.call.muted") }
    package static var callUnmuted: String { key("touchpoint.call.unmuted") }
    package static func callRoute(_ device: String) -> String { String(format: key("touchpoint.call.route"), device) }
    package static var muteLabel: String { key("touchpoint.call.action.mute") }
    package static var unmuteLabel: String { key("touchpoint.call.action.unmute") }
    package static var openChatLabel: String { key("touchpoint.call.action.openChat") }
    package static var endCallLabel: String { key("touchpoint.call.action.end") }
    package static var voiceRailLabel: String { key("touchpoint.call.rail.label") }
    package static var voiceMenuLabel: String { key("touchpoint.call.action.menu") }
    package static var audioRouteLabel: String { key("touchpoint.call.action.audioRoute") }

    // MARK: Voice full screen (VO-1…VO-5)

    /// Header toggle for the other side's audio (web's Speakers control, VO-4).
    package static var speakersLabel: String { key("touchpoint.call.action.speakers") }
    package static var speakersOnValue: String { key("touchpoint.call.speakers.on") }
    package static var speakersOffValue: String { key("touchpoint.call.speakers.off") }
    /// The ended screen (web's FullscreenVoice terminated branch, VO-2).
    package static var callEndedTitle: String { key("touchpoint.call.ended.title") }
    package static var callEndedBody: String { key("touchpoint.call.ended.body") }
    /// The failed screen (web's FullscreenError + Retry, VO-2).
    package static var callErrorTitle: String { key("touchpoint.call.error.title") }
    package static var callErrorBody: String { key("touchpoint.call.error.body") }
    package static var callErrorHint: String { key("touchpoint.call.error.hint") }
    package static var callRetryLabel: String { key("touchpoint.call.error.retry") }
    package static var attachmentUploadLabel: String { key("touchpoint.attachment.upload") }
    package static var attachmentDeleteLabel: String { key("touchpoint.attachment.delete") }
    package static func attachmentTooBig(megabytes: Int) -> String { String(format: key("touchpoint.attachment.tooBig"), megabytes) }
    package static var attachmentUploadFailed: String { key("touchpoint.attachment.uploadFailed") }
    package static var attachmentGenericError: String { key("touchpoint.attachment.generic") }
    package static var attachmentUploading: String { key("touchpoint.attachment.uploading") }
    package static var attachmentUploaded: String { key("touchpoint.attachment.uploaded") }
    package static var attachmentOpenFailed: String { key("touchpoint.attachment.openFailed") }
    package static func attachmentLabel(_ name: String) -> String { String(format: key("touchpoint.attachment.label"), name) }
    /// Web's label for a choice that carries no text of its own: "Option 2".
    package static func untitledChoice(_ position: Int) -> String { String(format: key("touchpoint.choice.untitled"), position) }
    package static var announcementReceived: String { key("touchpoint.announcement.received") }
    package static func announcementChoices(_ count: Int) -> String {
        String(format: key(count == 1 ? "touchpoint.announcement.choice" : "touchpoint.announcement.choices"), count)
    }
    package static var authenticationHeading: String { key("touchpoint.authentication.heading") }
    package static var authenticationAuthenticate: String { key("touchpoint.authentication.authenticate") }
    package static var authenticationSkip: String { key("touchpoint.authentication.skip") }
    package static var authenticationLockedHint: String { key("touchpoint.authentication.lockedHint") }
    package static func authenticationStatus(_ status: AuthenticationStatus) -> String {
        key("touchpoint.authentication.status.\(status.rawValue)")
    }
    package static var screenShareLabel: String { key("touchpoint.call.action.screenShare") }
    package static var stopScreenShareLabel: String { key("touchpoint.call.action.stopScreenShare") }
    package static var screenShareAvailable: String { key("touchpoint.call.screenShare.available") }
    package static var screenShareStarted: String { key("touchpoint.call.screenShare.started") }
    package static var screenShareStopped: String { key("touchpoint.call.screenShare.stopped") }
    package static var launchButtonLabel: String { key("touchpoint.launch.label") }
    package static var suggestedRepliesLabel: String { key("touchpoint.suggestedReplies.label") }
    package static var suggestedReplyHint: String { key("touchpoint.suggestedReplies.hint") }

    /// Resolves a catalog key, applying host overrides and the device (or host-forced) language.
    ///
    /// Order: a host override (``TouchpointCopy/overrides``) wins over everything; otherwise the
    /// language is resolved from ``TouchpointCopy/languageCode`` or the device's preferred language
    /// with web's rules (`touchpointTranslationCode`), and the string is looked up in that
    /// `.lproj` sub-bundle; anything missing there falls back to the `en` source.
    ///
    /// **Deviation (platform norm):** the language is chosen from `Locale.preferredLanguages` and
    /// the matching `.lproj` is loaded explicitly, rather than relying on `Bundle.module`'s own
    /// localisation. Apple would intersect the catalog's languages with the *host app's* declared
    /// localizations, so a host that does not list, say, Japanese would pin every user to English.
    /// Web follows `navigator.language` regardless of the page; this follows the device the same way.
    ///
    /// `String.LocalizationValue` needs a literal, so the dynamic lookup goes through
    /// `Bundle.localizedString`; the key is returned unchanged if it is missing from every bundle.
    private static func key(_ k: String) -> String {
        let store = LocalizationStore.shared
        if let override = store.override(for: k) { return override }
        let preferred = store.languageCode ?? Locale.preferredLanguages.first ?? "en"
        if let code = touchpointTranslationCode(for: preferred),
           let bundle = store.localizedBundle(for: code) {
            let value = bundle.localizedString(forKey: k, value: missingSentinel, table: nil)
            if value != missingSentinel { return value }
        }
        return Bundle.module.localizedString(forKey: k, value: nil, table: nil)
    }

    /// Returned by `localizedString(forKey:value:table:)` when a key is absent from a localised
    /// sub-bundle, so a missing translation can be told apart from a translation and fall back to
    /// `en`. A NUL-wrapped string no real value can equal.
    private static let missingSentinel = "\u{0}__touchpoint_missing__\u{0}"
}
