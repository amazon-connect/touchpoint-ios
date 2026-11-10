// Scaled-metrics must-pass fixture: scaled metrics, zero gaps, and arithmetic over a metric are all allowed.
import SwiftUI

struct ScaledOnly: View {
    let metrics: Metrics
    var body: some View {
        VStack(spacing: 0) {
            Text("a").font(.body)
            Text("b").font(.caption2)
            Text("c").padding(metrics.pad)
            Text("d").padding(.horizontal, metrics.pad)
            Text("e").frame(minHeight: metrics.tapTarget)
            HStack(spacing: metrics.pad / 2) { Text("f") }
            RoundedRectangle(cornerRadius: metrics.radius)
        }
        .frame(maxWidth: .infinity)
        .padding(0)
    }
    // Plain geometry is not typography: these must not trip scaled-metrics even in a view file.
    let intrinsic = CGSize(width: 100, height: 50)
    let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
    func rowHeight(_ n: Int) -> Int { n * 2 }

    struct Metrics { var pad: CGFloat; var tapTarget: CGFloat; var radius: CGFloat }
}
