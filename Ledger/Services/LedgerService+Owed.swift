import Foundation
import SwiftData
import os

/// The billing terms of a credit card or pay later account.
struct OwedTerms: Equatable, Sendable {
    /// Day of the month the statement closes. Required for credit cards and pay later.
    var statementDay: Int?
    var dueDay: Int
    var creditLimit: Decimal?
    /// Cashback on purchases as a percentage, credit cards only.
    var cashbackPercent: Decimal?
    /// Whether the service counts fees against the limit, pay later only.
    var feesUseLimit: Bool

    init(
        statementDay: Int?,
        dueDay: Int,
        creditLimit: Decimal? = nil,
        cashbackPercent: Decimal? = nil,
        feesUseLimit: Bool = false
    ) {
        self.statementDay = statementDay
        self.dueDay = dueDay
        self.creditLimit = creditLimit
        self.cashbackPercent = cashbackPercent
        self.feesUseLimit = feesUseLimit
    }
}

extension LedgerService {
    /// Days of the month a statement or due day may be set to. Days past a month's end mean its last day.
    static let dayRange = 1...31

    // MARK: Credit cards and pay later

    /// Creates a credit card or pay later account that owes `owedNow`.
    ///
    /// `stillDue` is the unpaid part of a statement that has already closed, for its upcoming
    /// due date (`awaitingDue(for:)`). It's required while a statement is waiting for payment,
    /// zero when it's paid, and must be `nil` otherwise.
    @discardableResult
    func createOwedAccount(
        name: String,
        kind: AccountKind,
        terms: OwedTerms,
        owedNow: Decimal,
        stillDue: Decimal?,
        currency: CurrencyCode = .php
    ) throws -> Account {
        guard kind == .creditCard || kind == .payLater else { throw LedgerError.wrongAccountGroup }
        let existing = try accounts(includeArchived: true)
        let cleanName = try validatedName(name, existingNames: existing.map(\.name))
        let validated = try validatedTerms(terms, for: kind, currency: currency)
        let owedMinor = try AmountRules.owedMinorUnits(owedNow, currency: currency)

        var waiting: (cycle: CalendarMonth, amountMinor: Int64)?
        if stillDue == nil, awaitingDue(for: validated.schedule) != nil {
            throw LedgerError.stillDueRequired
        }
        if let stillDue {
            let stillDueMinor = try AmountRules.owedMinorUnits(stillDue, currency: currency)
            guard let due = awaitingDue(for: validated.schedule) else { throw LedgerError.stillDueNotApplicable }
            guard stillDueMinor <= owedMinor else { throw LedgerError.stillDueAboveOwed }
            waiting = (CalendarMonth(containing: due), stillDueMinor)
        }

        let account = Account(
            name: cleanName,
            kind: kind,
            currency: currency,
            openingBalanceMinor: -owedMinor,
            createdAt: now,
            sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1
        )
        validated.apply(to: account)
        context.insert(account)
        if let waiting {
            context.insert(DueOverride(ownerID: account.id, cycle: waiting.cycle.storedValue, amountMinor: waiting.amountMinor))
        }
        try commit()
        Log.ledger.info("Created an owed account")
        return account
    }

    /// Renames an owed account or changes its billing terms.
    func updateOwedAccount(_ account: Account, name: String, terms: OwedTerms) throws {
        guard account.modelContext != nil, !account.isDeleted else { throw LedgerError.accountNotFound }
        guard account.kind.isOwed else { throw LedgerError.wrongAccountGroup }
        let others = try accounts(includeArchived: true).filter { $0.id != account.id }
        let cleanName = try validatedName(name, existingNames: others.map(\.name))
        let validated = try validatedTerms(terms, for: account.kind, currency: account.currency)
        account.name = cleanName
        validated.apply(to: account)
        try commit()
        Log.ledger.info("Updated an owed account")
    }

    /// The due date a "still due" amount refers to: the upcoming due whose statement has already
    /// closed. `nil` when no closed statement is waiting for payment.
    func awaitingDue(for schedule: DueSchedule) -> CalendarDay? {
        let today = CalendarDay(containing: now, calendar: calendar)
        let cycle = schedule.cycle(dueOnOrAfter: today)
        guard let close = schedule.statementClose(for: cycle), close < today else { return nil }
        return schedule.dueDate(in: cycle)
    }

    // MARK: Validation

    struct ValidatedOwedTerms {
        let schedule: DueSchedule
        let creditLimitMinor: Int64?
        let cashbackRatePPM: Int64?
        let feesUseLimit: Bool

        func apply(to account: Account) {
            account.statementDay = schedule.statementDay
            account.dueDay = schedule.dueDay
            account.creditLimitMinor = creditLimitMinor
            account.cashbackRatePPM = cashbackRatePPM
            account.feesUseLimit = feesUseLimit
        }
    }

    /// Checks billing terms for an owed kind. Loans have no statement day.
    func validatedTerms(_ terms: OwedTerms, for kind: AccountKind, currency: CurrencyCode) throws -> ValidatedOwedTerms {
        guard kind.isOwed else { throw LedgerError.wrongAccountGroup }
        guard Self.dayRange.contains(terms.dueDay) else { throw LedgerError.dayOutOfRange }
        var statementDay: Int?
        if kind != .loan {
            guard let day = terms.statementDay else { throw LedgerError.statementDayRequired }
            guard Self.dayRange.contains(day) else { throw LedgerError.dayOutOfRange }
            statementDay = day
        }
        let limitMinor = try terms.creditLimit.map { try AmountRules.owedMinorUnits($0, currency: currency) }
        var cashbackPPM: Int64?
        if let percent = terms.cashbackPercent {
            guard kind == .creditCard else { throw LedgerError.cashbackNotOffered }
            cashbackPPM = try RateRules.cashbackRate(percent: percent).partsPerMillion
        }
        return ValidatedOwedTerms(
            schedule: DueSchedule(statementDay: statementDay, dueDay: terms.dueDay),
            creditLimitMinor: limitMinor,
            cashbackRatePPM: cashbackPPM,
            feesUseLimit: kind == .payLater && terms.feesUseLimit
        )
    }
}
