import Foundation
import SwiftData

/// Version 3 of the persisted schema: adds money the user owes and regular bills.
///
/// Accounts gain a due schedule, a credit limit, a cashback rate, and a reminder setting.
/// Transactions gain links to the purchase a cashback entry belongs to, to a payment plan, and
/// to the bill cycle they pay. New models hold payment plans, regular bills, and one-off changes
/// to a single due.
///
/// Every stored property has a default value and every relationship is optional, which keeps
/// the schema compatible with lightweight migrations and with CloudKit should sync be added.
/// Never edit a shipped schema version in place: add a new version, a migration stage in
/// `LedgerMigrationPlan`, and point the type aliases at the new models.
enum LedgerSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Account.self, LedgerCategory.self, LedgerTransaction.self, PaymentPlan.self, Bill.self, DueOverride.self]
    }

    /// A place money is kept (a bank account, an e-wallet, or cash) or money is owed (a credit
    /// card, a pay later service, or a loan).
    @Model
    final class Account {
        /// Stable identifier, also used by App Intents.
        var id: UUID = UUID()
        var name: String = ""
        var kindRaw: String = AccountKind.other.rawValue
        var currencyCode: String = CurrencyCode.php.rawValue
        /// Balance before any transaction recorded in Ledger, in minor units. Negative while an
        /// owed account starts out owing money.
        /// `nil` means the user hasn't entered it; it is never assumed to be zero.
        var openingBalanceMinor: Int64? = nil
        var createdAt: Date = Date.now
        var isArchived: Bool = false
        var archivedAt: Date? = nil
        var sortOrder: Int = 0
        /// Annual interest rate in parts per million (3.25% is 32_500). `nil` means the account
        /// doesn't earn interest.
        var interestRatePPM: Int64? = nil
        /// Withholding tax on interest, in parts per million (20% is 200_000).
        var interestTaxRatePPM: Int64 = 200_000
        /// The last calendar day whose interest has been posted, as yyyymmdd. `nil` while
        /// interest is off.
        var interestPaidThrough: Int? = nil
        /// Day of the month a card or pay later statement closes. `nil` for loans and money accounts.
        var statementDay: Int? = nil
        /// Day of the month payment is due. `nil` for money accounts.
        var dueDay: Int? = nil
        /// Credit or spending limit, in minor units. `nil` when not entered.
        var creditLimitMinor: Int64? = nil
        /// Cashback on card purchases, in parts per million (1% is 10_000). `nil` means none.
        var cashbackRatePPM: Int64? = nil
        /// Whether due reminders for this account stay until paid.
        var strictReminder: Bool = true

        /// Expenses, income, adjustments, and outgoing transfers that use this account.
        @Relationship(deleteRule: .nullify, inverse: \LedgerTransaction.account)
        var transactions: [LedgerTransaction]? = []

        /// Transfers whose destination is this account.
        @Relationship(deleteRule: .nullify, inverse: \LedgerTransaction.destinationAccount)
        var incomingTransfers: [LedgerTransaction]? = []

        /// Payment plans (splits and loans) paid through this account.
        @Relationship(deleteRule: .cascade, inverse: \PaymentPlan.account)
        var plans: [PaymentPlan]? = []

        /// Regular bills usually paid from this account.
        @Relationship(deleteRule: .nullify, inverse: \Bill.payFrom)
        var billsPaidFrom: [Bill]? = []

        init(
            id: UUID = UUID(),
            name: String,
            kind: AccountKind,
            currency: CurrencyCode = .php,
            openingBalanceMinor: Int64?,
            createdAt: Date,
            sortOrder: Int
        ) {
            self.id = id
            self.name = name
            self.kindRaw = kind.rawValue
            self.currencyCode = currency.rawValue
            self.openingBalanceMinor = openingBalanceMinor
            self.createdAt = createdAt
            self.sortOrder = sortOrder
        }
    }

    /// An expense category or an income source.
    @Model
    final class LedgerCategory {
        var id: UUID = UUID()
        var name: String = ""
        var kindRaw: String = CategoryKind.expense.rawValue
        var symbolName: String = CategoryKind.expense.defaultSymbolName
        var isArchived: Bool = false
        var archivedAt: Date? = nil
        var sortOrder: Int = 0
        var createdAt: Date = Date.now

        @Relationship(deleteRule: .nullify, inverse: \LedgerTransaction.category)
        var transactions: [LedgerTransaction]? = []

        /// Regular bills recorded in this category.
        @Relationship(deleteRule: .nullify, inverse: \Bill.category)
        var bills: [Bill]? = []

        init(
            id: UUID = UUID(),
            name: String,
            kind: CategoryKind,
            symbolName: String,
            createdAt: Date,
            sortOrder: Int
        ) {
            self.id = id
            self.name = name
            self.kindRaw = kind.rawValue
            self.symbolName = symbolName
            self.createdAt = createdAt
            self.sortOrder = sortOrder
        }
    }

    /// One logical money movement. A transfer is a single record holding both its outgoing
    /// (`account`) and incoming (`destinationAccount`) sides, so it is saved atomically and
    /// can never be half-recorded.
    @Model
    final class LedgerTransaction {
        #Index<LedgerTransaction>([\.occurredAt], [\.createdAt], [\.requestID])

        var id: UUID = UUID()
        var kindRaw: String = TransactionKind.expense.rawValue
        var statusRaw: String = TransactionStatus.posted.rawValue
        /// Always positive, in minor units. The kind determines the direction.
        var amountMinor: Int64 = 0
        var currencyCode: String = CurrencyCode.php.rawValue
        /// When the money moved. Stored as an absolute instant and displayed in the local time zone.
        var occurredAt: Date = Date.now
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now
        var note: String? = nil
        /// Expense: account paid from. Income: account received into. Transfer: source account.
        /// Adjustment: account corrected.
        var account: Account? = nil
        /// Transfer destination. `nil` for other kinds.
        var destinationAccount: Account? = nil
        /// Expense category or income source. `nil` for transfers, adjustments, and automatic entries.
        var category: LedgerCategory? = nil
        var originRaw: String = EntryOrigin.app.rawValue
        /// Optional external reference, such as a receipt or reference number.
        var reference: String? = nil
        /// Client-generated key that makes a submission idempotent.
        var requestID: UUID? = nil
        /// Whether an adjustment raised or lowered the balance. `nil` for other kinds.
        var directionRaw: String? = nil
        /// What an automatic entry was calculated from, in minor units: the day's ending balance
        /// for interest, the gross interest for withholding tax, the purchase for cashback.
        var basisMinor: Int64? = nil
        /// The rate applied to `basisMinor`, in parts per million.
        var basisRatePPM: Int64? = nil
        /// For cashback, the purchase it was earned on.
        var sourceTransactionID: UUID? = nil
        /// The payment plan a split purchase or its fees belong to.
        var planID: UUID? = nil
        /// The regular bill an expense pays, with the cycle it pays as yyyymm.
        var billID: UUID? = nil
        var billCycle: Int? = nil

        init(
            id: UUID = UUID(),
            kind: TransactionKind,
            amountMinor: Int64,
            currency: CurrencyCode,
            occurredAt: Date,
            createdAt: Date,
            note: String?,
            account: Account,
            destinationAccount: Account?,
            category: LedgerCategory?,
            origin: EntryOrigin,
            reference: String?,
            requestID: UUID?
        ) {
            self.id = id
            self.kindRaw = kind.rawValue
            self.statusRaw = TransactionStatus.posted.rawValue
            self.amountMinor = amountMinor
            self.currencyCode = currency.rawValue
            self.occurredAt = occurredAt
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.note = note
            self.account = account
            self.destinationAccount = destinationAccount
            self.category = category
            self.originRaw = origin.rawValue
            self.reference = reference
            self.requestID = requestID
        }
    }

    /// Monthly payments for a split purchase or a loan, due on the owed account's due dates.
    @Model
    final class PaymentPlan {
        var id: UUID = UUID()
        /// What the payments are for, such as the item bought.
        var title: String = ""
        var account: Account? = nil
        /// Each monthly payment, in minor units, except the last.
        var monthlyMinor: Int64 = 0
        /// The last payment, in minor units; the same as `monthlyMinor` unless the total doesn't
        /// divide evenly.
        var lastMinor: Int64 = 0
        var months: Int = 0
        /// Payments already made before the plan was added to Ledger.
        var paidAtStart: Int = 0
        /// Due date of the first payment still to make, as yyyymmdd.
        var firstDue: Int = 0
        var createdAt: Date = Date.now
        /// The purchase and fee entries recorded with the plan, if any.
        var purchaseID: UUID? = nil
        var feesID: UUID? = nil

        init(
            id: UUID = UUID(),
            title: String,
            account: Account,
            monthlyMinor: Int64,
            lastMinor: Int64,
            months: Int,
            paidAtStart: Int,
            firstDue: Int,
            createdAt: Date
        ) {
            self.id = id
            self.title = title
            self.account = account
            self.monthlyMinor = monthlyMinor
            self.lastMinor = lastMinor
            self.months = months
            self.paidAtStart = paidAtStart
            self.firstDue = firstDue
            self.createdAt = createdAt
        }
    }

    /// A bill paid every month, such as rent or electricity.
    @Model
    final class Bill {
        var id: UUID = UUID()
        var name: String = ""
        /// The expense category its payments are recorded in.
        var category: LedgerCategory? = nil
        var dueDay: Int = 1
        /// The monthly amount, in minor units. `nil` when it varies and is entered each month.
        var amountMinor: Int64? = nil
        /// Day of the month a varying bill usually arrives.
        var arrivesDay: Int? = nil
        /// The account the bill is usually paid from.
        var payFrom: Account? = nil
        var isArchived: Bool = false
        var archivedAt: Date? = nil
        var sortOrder: Int = 0
        var createdAt: Date = Date.now
        /// The first cycle tracked, as yyyymm. Earlier cycles are never due.
        var startCycle: Int = 0
        /// Whether due reminders for this bill stay until paid.
        var strictReminder: Bool = true

        init(
            id: UUID = UUID(),
            name: String,
            category: LedgerCategory?,
            dueDay: Int,
            amountMinor: Int64?,
            arrivesDay: Int?,
            payFrom: Account?,
            createdAt: Date,
            startCycle: Int,
            sortOrder: Int
        ) {
            self.id = id
            self.name = name
            self.category = category
            self.dueDay = dueDay
            self.amountMinor = amountMinor
            self.arrivesDay = arrivesDay
            self.payFrom = payFrom
            self.createdAt = createdAt
            self.startCycle = startCycle
            self.sortOrder = sortOrder
        }
    }

    /// A change to one cycle of an owed account or a bill: a moved due date, this month's amount
    /// of a varying bill, or what was still due when an owed account was added.
    @Model
    final class DueOverride {
        var id: UUID = UUID()
        /// The owed account or bill.
        var ownerID: UUID = UUID()
        /// The cycle changed, as yyyymm of its original due date.
        var cycle: Int = 0
        /// The new due date, as yyyymmdd.
        var movedTo: Int? = nil
        /// The cycle's amount, in minor units.
        var amountMinor: Int64? = nil

        init(id: UUID = UUID(), ownerID: UUID, cycle: Int, movedTo: Int? = nil, amountMinor: Int64? = nil) {
            self.id = id
            self.ownerID = ownerID
            self.cycle = cycle
            self.movedTo = movedTo
            self.amountMinor = amountMinor
        }
    }
}

/// Migration plan for the persisted schema. New versions append a schema and a stage here;
/// existing financial records must always be carried forward, never dropped.
enum LedgerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LedgerSchemaV1.self, LedgerSchemaV2.self, LedgerSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: LedgerSchemaV1.self, toVersion: LedgerSchemaV2.self),
            .lightweight(fromVersion: LedgerSchemaV2.self, toVersion: LedgerSchemaV3.self),
        ]
    }
}

typealias Account = LedgerSchemaV3.Account
typealias LedgerCategory = LedgerSchemaV3.LedgerCategory
typealias LedgerTransaction = LedgerSchemaV3.LedgerTransaction
typealias PaymentPlan = LedgerSchemaV3.PaymentPlan
typealias Bill = LedgerSchemaV3.Bill
typealias DueOverride = LedgerSchemaV3.DueOverride
