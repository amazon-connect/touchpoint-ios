import Foundation

/// Synthetic Acme Bank data. **Every value is invented**: names, numbers, merchants and amounts.
///
/// Dates are generated relative to today so the showcase keeps working. The dispute walkthrough has
/// the customer say "about two hundred and forty dollars, last Tuesday" and the assistant find it;
/// a fixed date would stop matching a fortnight after it was written (plan: "fixture data is
/// load-bearing and must not age").
enum DemoData {
    static let customerName = "Jordan Rivera"

    static func accounts(today: Date = .now, calendar: Calendar = .current) -> [Account] {
        let t = transactions(today: today, calendar: calendar)
        return [
            Account(id: "chk", kind: .chequing, nickname: "Everyday Chequing", maskedNumber: "•••• 4821",
                    balance: 3_418.27, transactions: t.filter { $0.accountID == "chk" }),
            Account(id: "sav", kind: .savings, nickname: "Rainy Day Savings", maskedNumber: "•••• 9034",
                    balance: 12_950.00, transactions: t.filter { $0.accountID == "sav" }),
            Account(id: "cc", kind: .creditCard, nickname: "\(PartnerBrand.bankShortName) Rewards Card", maskedNumber: "•••• 7716",
                    balance: -1_284.63, transactions: t.filter { $0.accountID == "cc" }),
        ]
    }

    /// The transaction the showcase disputes: $240.00 at "Riverside Auto", last Tuesday, on the card.
    static let disputeCandidateMerchant = "Riverside Auto"
    static let disputeCandidateAmount: Decimal = 240.00

    static func transactions(today: Date = .now, calendar: Calendar = .current) -> [Transaction] {
        let day = { (n: Int) in calendar.date(byAdding: .day, value: -n, to: calendar.startOfDay(for: today)) ?? today }
        let lastTuesday = Self.lastTuesday(before: today, calendar: calendar)
        return [
            Transaction(id: "t1", accountID: "cc", merchant: "Northgate Grocers", amount: -86.12, date: day(1), category: .groceries),
            Transaction(id: "t2", accountID: "cc", merchant: "Streamline Video", amount: -15.99, date: day(2), category: .subscriptions),
            Transaction(id: "t3", accountID: "cc", merchant: Self.disputeCandidateMerchant, amount: -Self.disputeCandidateAmount, date: lastTuesday, category: .automotive),
            Transaction(id: "t4", accountID: "cc", merchant: "Blue Fern Café", amount: -7.45, date: day(4), category: .dining),
            Transaction(id: "t5", accountID: "cc", merchant: "Harbourline Transit", amount: -3.35, date: day(5), category: .transport),
            Transaction(id: "t6", accountID: "cc", merchant: "Meridian Pharmacy", amount: -42.80, date: day(9), category: .health),
            Transaction(id: "t7", accountID: "cc", merchant: "Payment — thank you", amount: 900.00, date: day(12), category: .payment),
            Transaction(id: "t8", accountID: "chk", merchant: "Payroll — Lumen Studios", amount: 2_640.00, date: day(3), category: .income),
            Transaction(id: "t9", accountID: "chk", merchant: "Rent — 14 Orchard Lane", amount: -1_750.00, date: day(7), category: .housing),
            Transaction(id: "t10", accountID: "chk", merchant: "Transfer to Rainy Day Savings", amount: -300.00, date: day(7), category: .transfer),
            Transaction(id: "t11", accountID: "chk", merchant: "City Utilities", amount: -118.40, date: day(10), category: .utilities),
            Transaction(id: "t12", accountID: "sav", merchant: "Transfer from Everyday Chequing", amount: 300.00, date: day(7), category: .transfer),
            Transaction(id: "t13", accountID: "sav", merchant: "Interest", amount: 9.63, date: day(14), category: .income),
        ]
    }

    /// The most recent Tuesday strictly before `today` — "last Tuesday" in the sense a customer
    /// means it. On a Tuesday that is seven days ago, never today.
    static func lastTuesday(before today: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: today)
        let weekday = calendar.component(.weekday, from: start)   // Sunday = 1 … Tuesday = 3
        var back = (weekday - 3 + 7) % 7
        if back == 0 { back = 7 }
        return calendar.date(byAdding: .day, value: -back, to: start) ?? start
    }
}

struct Account: Identifiable, Hashable {
    enum Kind: String { case chequing, savings, creditCard }
    let id: String
    let kind: Kind
    let nickname: String
    let maskedNumber: String
    let balance: Decimal
    let transactions: [Transaction]

    var kindLabel: String {
        switch kind {
        case .chequing: "Chequing"
        case .savings: "Savings"
        case .creditCard: "Credit card"
        }
    }
}

struct Transaction: Identifiable, Hashable {
    enum Category: String { case groceries, subscriptions, automotive, dining, transport, health, payment, income, housing, transfer, utilities }
    let id: String
    let accountID: String
    let merchant: String
    /// Negative is money out.
    let amount: Decimal
    let date: Date
    let category: Category

    var symbolName: String {
        switch category {
        case .groceries: "cart"
        case .subscriptions: "play.rectangle"
        case .automotive: "car"
        case .dining: "cup.and.saucer"
        case .transport: "tram"
        case .health: "cross.case"
        case .payment, .transfer: "arrow.left.arrow.right"
        case .income: "arrow.down.circle"
        case .housing: "house"
        case .utilities: "bolt"
        }
    }
}

/// A narrowing of the transaction list the assistant applied. Loose on purpose: a spoken amount is
/// approximate, a merchant is a fragment, a date is the day.
struct TransactionFilter: Equatable {
    var amount: Decimal?
    var date: String?       // YYYY-MM-DD
    var merchant: String?

    func matches(_ t: Transaction) -> Bool {
        if let amount, abs(abs(t.amount) - abs(amount)) > 1 { return false }
        if let merchant, !merchant.isEmpty, !t.merchant.localizedCaseInsensitiveContains(merchant) { return false }
        if let date, !date.isEmpty {
            // "Last Tuesday" resolved by a model whose idea of today may be a day off from the
            // device's: match within a day either side rather than demanding equality.
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
            f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
            if let wanted = f.date(from: date), abs(wanted.timeIntervalSince(t.date)) > 36 * 3600 { return false }
        }
        return true
    }

    /// The transactions this filter shows. Amount is the reliable part of a spoken request; a
    /// misheard merchant ("Delta" for "Dell") or a wrongly resolved date must not hide the charge,
    /// so when nothing matches every field, the amount alone decides.
    func apply(to transactions: [Transaction]) -> [Transaction] {
        let exact = transactions.filter(matches)
        guard exact.isEmpty, amount != nil, merchant?.isEmpty == false || date?.isEmpty == false else { return exact }
        return transactions.filter(TransactionFilter(amount: amount).matches)
    }
}
