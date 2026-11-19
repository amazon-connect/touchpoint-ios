import Foundation
import Testing
@testable import AcmeBank

/// The one piece of the demo that is load-bearing: the showcase has the assistant find "about two
/// hundred and forty dollars, last Tuesday", so the fixture must keep producing that transaction
/// relative to whatever day the demo is run.
@Suite("Acme Bank fixture data")
struct DemoDataTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d)) ?? .distantPast
    }

    @Test("lastTuesday is strictly before today, on a Tuesday, within the last seven days")
    func lastTuesdayShape() {
        for offset in 0..<14 {
            let today = calendar.date(byAdding: .day, value: offset, to: date(2026, 10, 8)) ?? .now
            let t = DemoData.lastTuesday(before: today, calendar: calendar)
            #expect(calendar.component(.weekday, from: t) == 3, "not a Tuesday for offset \(offset)")
            let back = calendar.dateComponents([.day], from: t, to: calendar.startOfDay(for: today)).day ?? -1
            #expect((1...7).contains(back), "\(back) days back for offset \(offset)")
        }
    }

    @Test("On a Tuesday, last Tuesday is a week ago, not today")
    func onATuesday() {
        let tuesday = date(2026, 10, 6)
        #expect(calendar.component(.weekday, from: tuesday) == 3)
        let t = DemoData.lastTuesday(before: tuesday, calendar: calendar)
        #expect(calendar.dateComponents([.day], from: t, to: tuesday).day == 7)
    }

    @Test("The dispute candidate is on the credit card, $240.00, dated last Tuesday — whatever today is")
    func disputeCandidateTracksToday() {
        for offset in [0, 3, 30, 365] {
            let today = calendar.date(byAdding: .day, value: offset, to: date(2026, 10, 8)) ?? .now
            let card = DemoData.accounts(today: today, calendar: calendar).first { $0.kind == .creditCard }
            let candidate = card?.transactions.first { $0.merchant == DemoData.disputeCandidateMerchant }
            #expect(candidate?.amount == -DemoData.disputeCandidateAmount)
            #expect(candidate?.date == DemoData.lastTuesday(before: today, calendar: calendar))
        }
    }

    @Test("No transaction is dated in the future, and every account has at least one")
    func noFutureDates() {
        let today = date(2026, 10, 8)
        for account in DemoData.accounts(today: today, calendar: calendar) {
            #expect(!account.transactions.isEmpty, "\(account.nickname) has no transactions")
            #expect(account.transactions.allSatisfy { $0.date <= today })
        }
    }

    @Test("Transaction ids are unique across accounts")
    func uniqueIDs() {
        let ids = DemoData.transactions(calendar: calendar).map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
