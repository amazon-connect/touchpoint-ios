// Fixture: must FAIL check-string-catalog.sh — a user-facing literal that bypasses the catalog.
import SwiftUI
struct BypassFixture: View {
    var body: some View { Text("Hello, support") }
}
