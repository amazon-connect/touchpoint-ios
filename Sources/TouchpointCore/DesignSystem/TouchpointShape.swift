import SwiftUI

/// The SDK's one rounded rectangle. Web's corners are CSS `border-radius`, which is circular; a
/// SwiftUI rounded rectangle defaults to the continuous (squircle) style, which reads softer at
/// 20–28pt radii (QA c41, D4). Every rounded shape in the SDK goes through here.
package enum TouchpointShape {
    package static func rounded(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .circular)
    }
}
