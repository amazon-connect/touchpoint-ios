// Scaled-metrics must-fail fixture: every line here is an absolute typographic or spacing value that the
// lint gate has to reject. One per line so a regression shows which form slipped through.
import SwiftUI

struct LiteralOffenders: View {
    var body: some View {
        VStack {
            Text("a").font(.system(size: 17))
            Text("b").font(Font.system(size: 13, weight: .bold))
            Text("c").font(.custom("Helvetica", size: 15))
            Text("d").padding(12)
            Text("e").padding(.horizontal, 20)
            Text("f").frame(minHeight: 44)
            Text("g").frame(width: 300)
            Text("g2").frame(height: 120)
            Text("h").lineSpacing(4)
            Spacer(minLength: 20)
            LazyVStack(spacing: 8) { Text("i") }
            HStack(alignment: .top, spacing: 6) { Text("j") }
            RoundedRectangle(cornerRadius: 14)
        }
    }
}

// A modifier split across lines hides the literal from a line-local check.
struct MultiLineOffender: View {
    var body: some View {
        Text("x")
            .frame(
                height: 44
            )
    }
}
