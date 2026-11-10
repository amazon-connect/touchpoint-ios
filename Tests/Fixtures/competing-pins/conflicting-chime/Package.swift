// swift-tools-version: 5.10
// An integrator already carrying Chime below TouchpointVoice's floor.
import PackageDescription

let package = Package(
    name: "BankAppConflictingChime",
    platforms: [.iOS(.v17)],
    dependencies: [
        .package(name: "Touchpoint", path: "../../../.."),
        .package(url: "https://github.com/aws/amazon-chime-sdk-ios-no-video-codecs-spm", exact: "0.26.0"),
    ],
    targets: [
        .target(name: "App", dependencies: [
            .product(name: "TouchpointVoice", package: "Touchpoint"),
            .product(name: "AmazonChimeSDK", package: "amazon-chime-sdk-ios-no-video-codecs-spm"),
        ]),
    ]
)
