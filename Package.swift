// swift-tools-version: 6.0
import PackageDescription

// Dependency version floors. Floors, not pins: a host app's own resolution may move
// upward, and a transitive conflict here is a link-time failure the integrator cannot work
// around. Raise a floor only when we depend on something newer.
// amazon-connect-chat-ios. Its own floor is aws-sdk-swift ≥ 1.6.47, so an app that also uses
// amplify-swift (which pins aws-sdk-swift exactly) needs amplify-swift ≥ 2.55.0.
let connectChatFloor: Version = "3.0.0"
let chimeFloor: Version = "0.27.4"         // amazon-chime-sdk-ios, no-video-codecs distribution

// Swift 6 language mode on every target. Deliberately *no* `defaultIsolation(MainActor.self)`:
// SE-0466 is an app-oriented opt-in, and this library's public protocols must stay callable from
// any isolation domain.
let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "Touchpoint",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17), // Set by the integration target, not vendor support windows
        .macOS(.v14), // unit tier runs on the development Mac with no simulator.
                         // Chime ships an iOS-only xcframework. The Connect chat SDK builds on
                         // macOS from 3.0, but it brings the AWS SDK for Swift and its C runtime,
                         // so both are linked `.when(platforms: [.iOS])` to keep the unit tier
                         // fast; on macOS the Chat and Voice targets compile against Core alone,
                         // and the adapters sit behind `#if canImport(...)`.
    ],
    products: [
        .library(name: "TouchpointCore", targets: ["TouchpointCore"]),
        .library(name: "TouchpointChat", targets: ["TouchpointChat"]),
        .library(name: "TouchpointVoice", targets: ["TouchpointVoice"]),
        .library(name: "TouchpointLiveSync", targets: ["TouchpointLiveSync"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/amazon-connect/amazon-connect-chat-ios",
            from: connectChatFloor
        ),
        .package(
            url: "https://github.com/aws/amazon-chime-sdk-ios-no-video-codecs-spm",
            from: chimeFloor
        ),
    ],
    targets: [
        // Coordination, persistence, theme tokens, UI primitives. No modality transport.
        .target(
            name: "TouchpointCore",
            resources: [.process("Resources")],   // String Catalog + PrivacyInfo.xcprivacy
            swiftSettings: swift6
        ),
        // Chat transport and transcript UI. Links the Connect chat SDK; must never link Chime.
        .target(
            name: "TouchpointChat",
            dependencies: [
                "TouchpointCore",
                .product(name: "AmazonConnectChatIOS", package: "amazon-connect-chat-ios", condition: .when(platforms: [.iOS])),
            ],
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: swift6
        ),
        // WebRTC session adapter, outbound CallKit, call UI. The only target that links Chime.
        .target(
            name: "TouchpointVoice",
            dependencies: [
                "TouchpointCore",
                .product(name: "AmazonChimeSDK", package: "amazon-chime-sdk-ios-no-video-codecs-spm", condition: .when(platforms: [.iOS])),
            ],
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: swift6
        ),
        // Live Sync protocol client and declarative action layer. Headless; Core only.
        .target(
            name: "TouchpointLiveSync",
            dependencies: ["TouchpointCore"],
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: swift6
        ),


        .testTarget(name: "TouchpointCoreTests", dependencies: ["TouchpointCore"], swiftSettings: swift6),
        .testTarget(name: "TouchpointChatTests", dependencies: ["TouchpointChat"], swiftSettings: swift6),
        .testTarget(name: "TouchpointVoiceTests", dependencies: ["TouchpointVoice"], swiftSettings: swift6),
        .testTarget(name: "TouchpointLiveSyncTests", dependencies: ["TouchpointLiveSync"], swiftSettings: swift6),
    ]
)
