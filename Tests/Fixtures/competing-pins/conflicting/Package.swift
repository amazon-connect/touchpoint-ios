// swift-tools-version: 5.10
// A realistic integrator: a bank app that already pins `amazon-connect-chat-ios` to an exact version
// *below* Touchpoint's declared floor. Resolution must fail with a diagnosable message that names the
// package — a silent success here would mean the floor is not actually enforced.
import PackageDescription

let package = Package(
    name: "BankAppConflicting",
    platforms: [.iOS(.v17)],
    dependencies: [
        .package(name: "Touchpoint", path: "../../../.."),
        .package(url: "https://github.com/amazon-connect/amazon-connect-chat-ios", exact: "2.0.0"),
    ],
    targets: [
        .target(name: "App", dependencies: [
            .product(name: "TouchpointChat", package: "Touchpoint"),
            .product(name: "AmazonConnectChatIOS", package: "amazon-connect-chat-ios"),
        ]),
    ]
)
