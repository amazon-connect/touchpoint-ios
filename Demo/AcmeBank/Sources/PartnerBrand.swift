import SwiftUI

/// The bank the demo presents as: Acme Bank by default, or a partner's brand when its folder is in
/// the demo. It names the app, the sign-in screen, the accounts, notifications and the partner
/// bank chat look (Settings → "Partner bank look"), and gives the app its tint.
///
/// **Reversible by design.** A partner brand lives entirely in `Demo/AcmeBank/Partner/<Name>/`:
/// its images, one Swift file that defines the `partner…` values below, and `brand.env`, which
/// `Scripts/demo-project.sh` (the app's display name) and `Scripts/env/lib.sh` (the live contact
/// flow's and assistant's wording) read. `Scripts/demo-project.sh` compiles that folder in, with the
/// `DEMO_PARTNER_BRAND` condition, only when it exists. Deleting the folder, regenerating the
/// project (`make demo-project`) and redeploying the showcase puts Acme back with no other edit;
/// nothing outside the folder names the partner.
struct PartnerBrand {
    /// The header's leading mark (web's `brandIcon`), fitted into a 40pt square.
    let headerMark: Image
    /// The title beside the mark.
    let chatTitle: String
    /// The assistant's name and avatar under participant info (web's `assistantName` /
    /// `assistantIcon`).
    let assistantName: String
    let assistantAvatar: Image

    /// Acme's: its mark in the partner configuration's green.
    @MainActor static let acme = PartnerBrand(headerMark: AcmeBrand.partnerMark, chatTitle: "Chat with Acme",
                                              assistantName: "Acme Assistant", assistantAvatar: AcmeBrand.partnerMark)

    /// The chat look in force: the partner's when its folder is compiled in, else Acme's.
    @MainActor static var current: PartnerBrand {
        #if DEMO_PARTNER_BRAND
        partner
        #else
        acme
        #endif
    }

    /// The bank's full name ("Acme Bank") and the short form used in running text ("Acme").
    static var bankName: String {
        #if DEMO_PARTNER_BRAND
        partnerBankName
        #else
        "Acme Bank"
        #endif
    }

    static var bankShortName: String {
        #if DEMO_PARTNER_BRAND
        partnerBankShortName
        #else
        "Acme"
        #endif
    }

    /// The app's tint and primary-action colour; `nil` keeps Acme's teal (`Palette.brand`).
    static var tint: Color? {
        #if DEMO_PARTNER_BRAND
        partnerTint
        #else
        nil
        #endif
    }

    /// The mark on the sign-in screen; `nil` keeps the SF Symbol Acme uses.
    @MainActor static var signInMark: Image? {
        #if DEMO_PARTNER_BRAND
        partner.headerMark
        #else
        nil
        #endif
    }

    /// An image shipped in a partner folder, by name; Acme's mark if it is missing, so a renamed
    /// file shows a placeholder rather than an empty header.
    @MainActor static func bundled(_ name: String) -> Image {
        UIImage(named: name).map { Image(uiImage: $0) } ?? AcmeBrand.partnerMark
    }
}
