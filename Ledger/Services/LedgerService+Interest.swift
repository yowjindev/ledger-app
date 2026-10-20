import Foundation
import SwiftData
import os

extension LedgerService {
    /// Turns an account's interest on (`terms`), changes its rates, or turns it off (`nil`).
    ///
    /// Interest already due is posted first, at the old rates. The new rates apply to every day
    /// not yet posted. Interest turned on starts with today; earlier days are never filled in.
    func setInterest(_ terms: InterestTerms?, for account: Account) throws {
        guard account.modelContext != nil, !account.isDeleted else { throw LedgerError.accountNotFound }
        if terms != nil, account.isArchived {
            throw LedgerError.accountArchived(name: account.name)
        }
        try postDueInterest()
        if let terms {
            if account.interestRatePPM == nil {
                let today = CalendarDay(containing: now, calendar: calendar)
                account.interestPaidThrough = today.adding(days: -1, calendar: calendar).storedValue
            }
            account.interestRatePPM = terms.annualRate.partsPerMillion
            account.interestTaxRatePPM = terms.taxRate.partsPerMillion
        } else {
            account.interestRatePPM = nil
            account.interestPaidThrough = nil
        }
        try commit()
        Log.ledger.info("Changed an account's interest")
    }

    /// Posts the interest and withholding tax for every completed day not yet posted, on every
    /// account that earns interest, in one save. A day is complete once it's past 1:00 the next
    /// day, when the bank credits it. Returns the number of entries recorded; nothing is saved
    /// when no day is due.
    @discardableResult
    func postDueInterest() throws -> Int {
        let lastDay = InterestCalculator.lastPostableDay(asOf: now, calendar: calendar)
        let due = try accounts(includeArchived: true).compactMap { account -> (Account, InterestTerms, CalendarDay)? in
            guard
                let terms = account.interestTerms,
                let stored = account.interestPaidThrough,
                let paidThrough = CalendarDay(storedValue: stored),
                paidThrough < lastDay
            else { return nil }
            return (account, terms, paidThrough)
        }
        guard !due.isEmpty else { return 0 }

        let movements = try context.fetch(FetchDescriptor<LedgerTransaction>()).compactMap(Movement.init)
        var recorded = 0
        for (account, terms, paidThrough) in due {
            let days = InterestCalculator.dailyInterest(
                account: AccountSnapshot(account),
                terms: terms,
                after: paidThrough,
                through: lastDay,
                movements: movements,
                calendar: calendar
            )
            for day in days {
                insertInterestEntry(.income, amountMinor: day.grossMinor, account: account, at: day.postedAt, basisMinor: day.balanceMinor, rate: day.annualRate)
                recorded += 1
                if day.taxMinor > 0 {
                    insertInterestEntry(.expense, amountMinor: day.taxMinor, account: account, at: day.postedAt, basisMinor: day.grossMinor, rate: day.taxRate)
                    recorded += 1
                }
            }
            account.interestPaidThrough = lastDay.storedValue
        }
        try commit()
        Log.ledger.info("Posted \(recorded, privacy: .public) interest entries")
        return recorded
    }

    private func insertInterestEntry(_ kind: TransactionKind, amountMinor: Int64, account: Account, at date: Date, basisMinor: Int64, rate: Rate) {
        let entry = LedgerTransaction(
            kind: kind,
            amountMinor: amountMinor,
            currency: account.currency,
            occurredAt: date,
            createdAt: now,
            note: nil,
            account: account,
            destinationAccount: nil,
            category: nil,
            origin: .interest,
            reference: nil,
            requestID: nil
        )
        entry.basisMinor = basisMinor
        entry.basisRatePPM = rate.partsPerMillion
        context.insert(entry)
    }
}
