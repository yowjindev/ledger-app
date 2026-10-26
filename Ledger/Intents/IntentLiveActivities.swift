import AppIntents
import Foundation

// Intents that save entries may start or replace the due reminder Live Activity while they run,
// which iOS allows only inside a Live Activity intent.
extension LogExpenseIntent: LiveActivityIntent {}
extension LogIncomeIntent: LiveActivityIntent {}
extension TransferMoneyIntent: LiveActivityIntent {}
extension LogFromMessageIntent: LiveActivityIntent {}
extension LedgerMenuIntent: LiveActivityIntent {}
