import Foundation

/// What a payment notification (a bank email or text message) says, as far as it can be read.
struct ParsedPaymentMessage: Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        /// Money left the account: a payment, purchase, transfer out, or withdrawal.
        case moneyOut
        /// Money arrived: a deposit, transfer in, or refund.
        case moneyIn
    }

    /// The transaction amount in pesos. Balances and limits mentioned in the message are ignored.
    var amount: Decimal?
    /// `nil` when the message doesn't say clearly, or mentions both directions.
    var direction: Direction?
    /// A reference or transaction number, used to notice a message logged twice.
    var reference: String?
}

/// Reads payment notifications on the device. Its result is only a suggestion: nothing is saved
/// until the person confirms it.
enum PaymentMessageParser {
    static func parse(_ message: String) -> ParsedPaymentMessage {
        let text = plainText(message)
        return ParsedPaymentMessage(
            amount: amount(in: text),
            direction: direction(in: text),
            reference: reference(in: text)
        )
    }

    /// The message with HTML tags removed and common entities decoded, so emails read like text.
    static func plainText(_ message: String) -> String {
        var text = message
        text = text.replacingOccurrences(of: "(?is)<(style|script)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<(br|/p|/div|/tr|/li|/h[1-6])[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // "&amp;" comes last so an escaped entity such as "&amp;nbsp;" is decoded only once.
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&#8369;", "₱"), ("&#x20b1;", "₱"), ("&peso;", "₱"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&"),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return text.replacingOccurrences(of: "[ \\t\\u00A0]+", with: " ", options: .regularExpression)
    }

    // MARK: Amount

    /// Words that, just before an amount, mark it as something other than the transaction amount.
    private static let ignoredAmountContexts = ["balance", "limit", "available"]
    /// Words that, just before an amount, mark it as the transaction amount.
    private static let preferredAmountContexts = ["amount", "total", "sent", "paid", "received", "transferred", "payment", "purchase", "deposit"]

    /// The transaction amount: the first peso amount introduced by a word like "amount" or "paid",
    /// otherwise the first peso amount that isn't a balance or limit, otherwise an unmarked number
    /// labelled "amount" or "total".
    static func amount(in text: String) -> Decimal? {
        let candidates = matches(of: "(?<![A-Za-z])(?:₱|[Pp][Hh][Pp]|P)\\s?([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\\.([0-9]{1,2}))?(?![0-9])", in: text)
            + matches(of: "(?i)\\b(?:amount|total)\\b[^0-9\\n]{0,20}?([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\\.([0-9]{1,2}))?(?![0-9])", in: text)
        var fallback: (position: Int, value: Decimal)?
        for candidate in candidates.sorted(by: { $0.position < $1.position }) {
            let context = candidate.context.lowercased()
            if ignoredAmountContexts.contains(where: context.contains) { continue }
            if preferredAmountContexts.contains(where: context.contains) { return candidate.value }
            if fallback == nil { fallback = (candidate.position, candidate.value) }
        }
        return fallback?.value
    }

    private struct AmountCandidate {
        let position: Int
        let value: Decimal
        /// Up to 30 characters before the amount.
        let context: String
    }

    private static func matches(of pattern: String, in text: String) -> [AmountCandidate] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let whole = source.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
            let fractionRange = match.range(at: 2)
            let fraction = fractionRange.location == NSNotFound ? "" : "." + source.substring(with: fractionRange)
            guard
                let value = Decimal(string: whole + fraction, locale: Locale(identifier: "en_US_POSIX")),
                value > .zero
            else { return nil }
            let contextStart = max(0, match.range.location - 30)
            let context = source.substring(with: NSRange(location: contextStart, length: match.range.location - contextStart))
            return AmountCandidate(position: match.range.location, value: value, context: context)
        }
    }

    // MARK: Direction

    private static let outgoingPhrases = [
        "you sent", "you have sent", "you've sent", "sent to", "you paid", "you have paid", "paid to",
        "payment to", "purchase", "debited", "withdraw", "cash out", "cash-out", "transferred to",
        "transfer to", "you transferred", "you have transferred", "successfully transferred", "spent",
        "bills payment", "bill payment",
    ]
    private static let incomingPhrases = [
        "you received", "you have received", "you've received", "received from", "credited",
        "deposit", "cash in", "cash-in", "transferred from", "transfer from", "refund", "incoming",
    ]

    /// Money out or in when the message says only one of them; otherwise `nil`.
    static func direction(in text: String) -> ParsedPaymentMessage.Direction? {
        let lowered = text.lowercased()
        let isOutgoing = outgoingPhrases.contains(where: lowered.contains)
        let isIncoming = incomingPhrases.contains(where: lowered.contains)
        switch (isOutgoing, isIncoming) {
        case (true, false): return .moneyOut
        case (false, true): return .moneyIn
        default: return nil
        }
    }

    // MARK: Reference

    /// A reference, transaction, or trace number, with spaces between digit groups removed
    /// ("1234 567 890123" becomes "1234567890123"). It must contain a digit, so ordinary words
    /// after "reference" aren't mistaken for one.
    static func reference(in text: String) -> String? {
        let pattern = "(?i)\\b(?:ref(?:erence)?|transaction|txn|trace)\\.?\\s*(?:no\\.?|number|id|#)?\\s*[:#]?\\s*([A-Z0-9][A-Z0-9-]{3,}(?: [0-9]{3,})*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let source = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let candidate = source.substring(with: match.range(at: 1)).replacingOccurrences(of: " ", with: "")
            if candidate.contains(where: \.isNumber) {
                return candidate.uppercased()
            }
        }
        return nil
    }
}
