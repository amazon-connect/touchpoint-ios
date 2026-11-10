// swift-tools-version: 5.10
// The same integrator with a pin at or above the floor: resolution must succeed and settle on one
// version of the Connect SDK for both the app and Touchpoint.
import PackageDescription

let package = Package(
    name: "BankAppCompatible",
    platforms: [.iOS(.v17)],
    dependencies: [
        .package(name: "Touchpoint", path: "../../../.."),
        .package(url: "https://github.com/amazon-connect/amazon-connect-chat-ios", from: "3.0.0"),
    ],
    targets: [
        .target(name: "App", dependencies: [
            .product(name: "TouchpointChat", package: "Touchpoint"),
            .product(name: "AmazonConnectChatIOS", package: "amazon-connect-chat-ios"),
        ]),
    ]
)
