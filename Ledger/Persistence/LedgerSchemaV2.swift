import Foundation
import SwiftData

/// Version 2 of the persisted schema: adds daily interest settings to accounts, and to
/// transactions the direction of a balance adjustment and what an automatic entry was
/// calculated from.
///
/// Every stored property has a default value and every relationship is optional, which keeps
/// the schema compatible with lightweight migrations and with CloudKit should sync be added.
/// Never edit a shipped schema version in place: add a new version, a migration stage in
/// `LedgerMigrationPlan`, and point the type aliases at the new models.
enum LedgerSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Account.self, LedgerCategory.self, LedgerTransaction.self]
    }

    /// A place money is kept: a bank account, an e-wallet, or cash.
    @Model
    final class Account {
        /// Stable identifier, also used by App Intents.
        var id: UUID = UUID()
        var name: String = ""
        var kindRaw: String = AccountKind.other.rawValue
        var currencyCode: String = CurrencyCode.php.rawValue
        /// Balance before any transaction recorded in Ledger, in minor units.
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

        /// Expenses, income, adjustments, and outgoing transfers that use this account.
        @Relationship(deleteRule: .nullify, inverse: \LedgerTransaction.account)
        var transactions: [LedgerTransaction]? = []

        /// Transfers whose destination is this account.
        @Relationship(deleteRule: .nullify, inverse: \LedgerTransaction.destinationAccount)
        var incomingTransfers: [LedgerTransaction]? = []

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
        /// for interest, the gross interest for withholding tax.
        var basisMinor: Int64? = nil
        /// The rate applied to `basisMinor`, in parts per million.
        var basisRatePPM: Int64? = nil

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
}

/// Migration plan for the persisted schema. New versions append a schema and a stage here;
/// existing financial records must always be carried forward, never dropped.
enum LedgerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LedgerSchemaV1.self, LedgerSchemaV2.self] }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: LedgerSchemaV1.self, toVersion: LedgerSchemaV2.self)]
    }
}

typealias Account = LedgerSchemaV2.Account
typealias LedgerCategory = LedgerSchemaV2.LedgerCategory
typealias LedgerTransaction = LedgerSchemaV2.LedgerTransaction
