# Changelog

Notable changes to the Amazon Connect Customer Touchpoint SDK for iOS, newest first. Versions
follow [Semantic Versioning](https://semver.org). Until 1.0.0, a minor release may change the
public API; a patch release never does. Each release is a git tag equal to `Touchpoint.version`.

Changes since the last release go under a `## [Unreleased]` heading at the top. How to release is
in [CONTRIBUTING.md](CONTRIBUTING.md#releasing).

## [0.1.0] - Unreleased

First public release.

### Added

- `TouchpointCore`: configuration, credential brokering through your `TouchpointBackend`, session
  coordination, an encrypted conversation store, theme tokens, and strings in 12 languages.
- `TouchpointChat`: chat with an Amazon Connect contact and its transcript UI: markdown, choices,
  cards and carousels, custom modalities, guide cards (Connect Views), attachments, sign-in
  (Authenticate Customer), window modes and the settings panel.
- `TouchpointVoice`: outbound WebRTC calls through CallKit, with in-app screen sharing and
  redaction.
- `TouchpointLiveSync`: Live Sync for a live chat or call: declarative actions, on-device payload
  validation, and consent and confirmation prompts.

### Requirements

- iOS 17.0 or later, Swift 6 language mode, Xcode 26 or later.
- `amazon-connect-chat-ios` 3.0.0 or later; Amazon Chime SDK for iOS (no-video-codecs) 0.27.4 or
  later.
