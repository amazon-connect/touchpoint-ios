import SwiftUI
import UIKit

/// Acme's brand images, drawn once in code — the demo ships no image assets. What a host would hand
/// the SDK as `brandIcon` / `assistantIcon`.
///
/// The header marks are **template** images: one ink, the "A" knocked out, so they take the
/// header's own ink — dark on a light panel, light on a dark one or on the brand header bar — as a
/// monochrome logo does on web. Drawn with Core Graphics' clear blend, which knocks out reliably;
/// SwiftUI's `destinationOut` does not under every renderer.
@MainActor
enum AcmeBrand {
    /// The square mark: a rounded tile with the "A" knocked out. "Logo + name" in the header.
    static let mark = Image(uiImage: render(wordmark: false).withRenderingMode(.alwaysTemplate))
    /// The wide logo: the mark and "Acme Bank" in one image — web's non-square brand icon. Drawn
    /// whole only in the mini window; the full and half windows fit it into a 40pt square (web).
    static let wideLogo = Image(uiImage: render(wordmark: true).withRenderingMode(.alwaysTemplate))
    /// The assistant's avatar: the mark in brand colours, which reads on either panel.
    static let avatar = Image(uiImage: renderAvatar(fill: UIColor(Palette.brand)))
    /// The partner look's header mark and avatar: the same tile in the partner's green with a white
    /// "A" — full colour, not a template, as a brand logo on a dark bar is.
    static let partnerMark = Image(uiImage: renderAvatar(fill: UIColor(Palette.Partner.green)))

    private static let side: CGFloat = 40

    private static func render(wordmark: Bool) -> UIImage {
        let name = NSAttributedString(string: "Acme Bank", attributes: [
            .font: UIFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: UIColor.black,
        ])
        let gap: CGFloat = 8
        let width = wordmark ? side + gap + ceil(name.size().width) : side
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: side)).image { context in
            UIColor.black.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: 10).fill()
            context.cgContext.setBlendMode(.clear)
            drawMonogram(in: CGRect(x: 0, y: 0, width: side, height: side), color: .black)
            context.cgContext.setBlendMode(.normal)
            if wordmark {
                let size = name.size()
                name.draw(at: CGPoint(x: side + gap, y: (side - size.height) / 2))
            }
        }
    }

    private static func renderAvatar(fill: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            fill.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: side, height: side))
            drawMonogram(in: CGRect(x: 0, y: 0, width: side, height: side), color: .white)
        }
    }

    private static func drawMonogram(in rect: CGRect, color: UIColor) {
        let letter = NSAttributedString(string: "A", attributes: [
            .font: UIFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: color,
        ])
        let size = letter.size()
        letter.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}
