// Fixture: passes the bypass grep — no user-facing string literal. An interpolation is a
// composition, not a catalog key, and a TouchpointStrings lookup is the sanctioned path.
import SwiftUI
struct CleanFixture: View {
    let name: String
    var body: some View { Text(TouchpointStrings.greeting) + Text("\(name)") }
}
