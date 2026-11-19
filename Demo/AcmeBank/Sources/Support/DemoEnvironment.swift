import Foundation

/// The live-mode settings: `LiveConfig.plist` in the app bundle, overridden by the launch
/// environment. `npm run app-config` in the demo backend prints the plist; with it the app reaches
/// the backend however it is launched (Xcode, the home screen, a test runner). Environment values,
/// which Xcode's scheme sets, win, so a run can point elsewhere without editing the file.
///
/// The plist holds identifiers only (the API endpoint, the Region, the Cognito pool and client ids,
/// the Connect instance URL), never a key or a credential: the app gets the Live Sync keys from the
/// backend after sign-in, and seeded IAM credentials are read from the launch environment alone.
enum DemoEnvironment {
    static let keys = [
        "ACME_LIVE_ENDPOINT", "ACME_LIVE_REGION",
        "ACME_COGNITO_USER_POOL_ID", "ACME_COGNITO_CLIENT_ID", "ACME_COGNITO_IDENTITY_POOL_ID",
        "ACME_CONNECT_INSTANCE_URL",
    ]

    /// Bundle values for `keys`, then the process environment on top.
    static let values: [String: String] = {
        var merged: [String: String] = [:]
        if let url = Bundle.main.url(forResource: "LiveConfig", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for key in keys { if let v = plist[key] as? String, !v.isEmpty { merged[key] = v } }
        }
        for (k, v) in ProcessInfo.processInfo.environment where !v.isEmpty { merged[k] = v }
        return merged
    }()
}
