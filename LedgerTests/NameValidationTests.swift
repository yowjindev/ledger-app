import Foundation
import XCTest
@testable import Ledger

/// Account and category names: trimming, length measured in visible characters, and duplicates
/// that differ only by case, diacritics, or character width, archived items included.
@MainActor
final class NameValidationTests: XCTestCase {
    func testNamesDifferingOnlyByCaseDiacriticsOrWidthAreDuplicates() throws {
        let h = try LedgerHarness()
        try h.account("Café", opening: nil)

        for variant in ["Cafe", "CAFÉ", "cafe\u{0301}", "Ｃａｆé", "ｃａｆｅ"] {
            assertThrowsLedgerError(.duplicateName(variant)) {
                try h.ledger.createAccount(name: variant, kind: .bank, openingBalance: nil)
            }
        }
        try h.expenseCategory("Ｆｏｏｄ")
        assertThrowsLedgerError(.duplicateName("food")) { try h.ledger.createCategory(name: "food", kind: .expense) }
        XCTAssertEqual(try h.ledger.accounts().map(\.name), ["Café"])
    }

    func testAllKindsOfSurroundingWhitespaceAreTrimmed() throws {
        let h = try LedgerHarness()

        let maya = try h.ledger.createAccount(name: "\u{3000} Maya\u{00A0}\n", kind: .eWallet, openingBalance: nil)
        XCTAssertEqual(maya.name, "Maya")
        assertThrowsLedgerError(.duplicateName("MAYA")) {
            try h.ledger.createAccount(name: "\u{3000}MAYA\u{3000}", kind: .bank, openingBalance: nil)
        }
        assertThrowsLedgerError(.emptyName) {
            try h.ledger.createAccount(name: "\u{3000}\u{00A0}\u{202F}\t", kind: .bank, openingBalance: nil)
        }
        let gym = try h.ledger.createCategory(name: " Gym\u{3000}", kind: .expense, symbolName: "  ")
        XCTAssertEqual(gym.name, "Gym")
        XCTAssertEqual(gym.symbolName, CategoryKind.expense.defaultSymbolName, "A blank symbol falls back to the default")
    }

    func testNameLengthCountsCharactersAsPeopleSeeThem() throws {
        let h = try LedgerHarness()
        let limit = LedgerService.nameLengthLimit
        let decomposed = String(repeating: "e\u{0301}", count: limit)
        let fullWidth = String(repeating: "Ｇ", count: limit)
        let families = String(repeating: "👨‍👩‍👧", count: limit)
        XCTAssertEqual(decomposed.unicodeScalars.count, 2 * limit)

        for name in [decomposed, fullWidth, families] {
            XCTAssertNoThrow(try h.ledger.createAccount(name: name, kind: .bank, openingBalance: nil), "\(name.count) characters")
        }
        for name in [decomposed + "e\u{0301}", fullWidth + "Ｈ", families + "👨‍👩‍👧"] {
            assertThrowsLedgerError(.nameTooLong(limit: limit)) {
                try h.ledger.createAccount(name: name, kind: .bank, openingBalance: nil)
            }
        }
        XCTAssertEqual(try h.ledger.accounts().count, 3)
    }

    func testArchivedAccountsAndCategoriesStillReserveTheirNames() throws {
        let h = try LedgerHarness()
        let maya = try h.account("Maya", opening: nil, kind: .eWallet)
        let pnb = try h.account("PNB", opening: nil)
        let haircut = try h.expenseCategory("Haircut")
        try h.ledger.archiveAccount(maya)
        try h.ledger.archiveCategory(haircut)

        assertThrowsLedgerError(.duplicateName("maya")) {
            try h.ledger.createAccount(name: "maya", kind: .eWallet, openingBalance: nil)
        }
        assertThrowsLedgerError(.duplicateName("Maya")) {
            try h.ledger.updateAccount(pnb, name: "Maya", kind: .bank, openingBalance: nil)
        }
        assertThrowsLedgerError(.duplicateName("HAIRCUT")) { try h.ledger.createCategory(name: "HAIRCUT", kind: .expense) }
        XCTAssertNoThrow(try h.ledger.createCategory(name: "Haircut", kind: .income), "Names are separate per kind")
        XCTAssertEqual(pnb.name, "PNB")
    }

    func testRenamingToAVariantOfItsOwnNameIsAllowed() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("Gcash", opening: nil, kind: .eWallet)
        let cafe = try h.expenseCategory("Cafe")

        try h.ledger.updateAccount(gcash, name: "GCASH", kind: .eWallet, openingBalance: nil)
        try h.ledger.updateCategory(cafe, name: "Café")

        XCTAssertEqual(gcash.name, "GCASH")
        XCTAssertEqual(cafe.name, "Café")
    }
}
