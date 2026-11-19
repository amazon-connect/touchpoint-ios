import UIKit

/// The offline demo's attachment: a one-page PDF drawn on first use into the caches directory.
enum DemoDisputeForm {
    static func url() throws -> URL {
        let url = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("\(PartnerBrand.bankShortName) dispute form v2.pdf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            context.beginPage()
            // An explicit page: without it the page is transparent, and a dark viewer draws black
            // text on black.
            UIColor.white.setFill()
            context.fill(page)
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 24)]
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14)]
            NSString(string: "\(PartnerBrand.bankName) — Dispute form").draw(at: CGPoint(x: 56, y: 64), withAttributes: title)
            let lines = ["Merchant: ____________________", "Amount: ____________________", "Date of charge: ____________________",
                         "What happened: ____________________", "", "Offline demo document. Not a real form."]
            for (i, line) in lines.enumerated() {
                NSString(string: line).draw(at: CGPoint(x: 56, y: 120 + i * 32), withAttributes: body)
            }
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
