// swift-tools-version: 5.10
// An integrator pinning `aws-sdk-swift` — not our dependency, but the Connect chat SDK's — below that
// SDK's own floor (≥ 1.6.47). This is the conflict an older amplify-swift brings, since it pins
// aws-sdk-swift exactly. It is one level down the graph and must still surface with the package
// named, because the integrator would otherwise not know which dependency to move.
import PackageDescription

let package = Package(
    name: "BankAppConflictingAWS",
    platforms: [.iOS(.v17)],
    dependencies: [
        .package(name: "Touchpoint", path: "../../../.."),
        .package(url: "https://github.com/awslabs/aws-sdk-swift", exact: "1.6.0"),
    ],
    targets: [
        .target(name: "App", dependencies: [
            .product(name: "TouchpointChat", package: "Touchpoint"),
            .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
        ]),
    ]
)
