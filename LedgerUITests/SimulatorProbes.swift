import Foundation
import SQLite3

/// Looks into Ledger's installation from the UI test runner. Simulator apps share the Mac's
/// file system, so the runner can read Ledger's app bundle and data container directly. None of
/// this works on a device; these tests are meant for the simulator.
enum LedgerInstallation {
    static let bundleIdentifier = "ph.personal.Ledger"

    /// The team identifier recorded in the installed app's code signature.
    enum SigningTeam: Equatable, CustomStringConvertible {
        case team(String)
        /// Signed to run locally (no development team).
        case none
        /// The app or its signature couldn't be read.
        case unknown

        var description: String {
            switch self {
            case .team(let identifier): "team \(identifier)"
            case .none: "no team (signed to run locally)"
            case .unknown: "unknown"
            }
        }
    }

    static func signingTeam() -> SigningTeam {
        guard let executable = appBundle()?.appendingPathComponent("Ledger"),
              let data = try? Data(contentsOf: executable, options: .mappedIfSafe) else { return .unknown }
        return CodeSignatureReader.team(inMachO: data)
    }

    /// Ledger's data container, a sibling of the test runner's own container.
    static func dataContainer() -> URL? {
        let applications = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        return containers(in: applications).first { identifier(ofContainer: $0) == bundleIdentifier }
    }

    /// The installed Ledger.app, found next to the test runner's bundle container.
    static func appBundle() -> URL? {
        let applications = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        return containers(in: applications)
            .first { identifier(ofContainer: $0) == bundleIdentifier }?
            .appendingPathComponent("Ledger.app")
    }

    private static func containers(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private static func identifier(ofContainer container: URL) -> String? {
        let metadata = container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        return (NSDictionary(contentsOf: metadata) as? [String: Any])?["MCMMetadataIdentifier"] as? String
    }
}

/// Reads the team identifier from the code directory of a thin 64-bit Mach-O executable.
private enum CodeSignatureReader {
    private static let machHeader64Magic: UInt32 = 0xFEED_FACF
    private static let codeSignatureCommand: UInt32 = 0x1D
    private static let embeddedSignatureMagic: UInt32 = 0xFADE_0CC0
    private static let codeDirectoryMagic: UInt32 = 0xFADE_0C02
    /// The first code directory version with a team identifier field.
    private static let teamFieldVersion: UInt32 = 0x20200

    static func team(inMachO data: Data) -> LedgerInstallation.SigningTeam {
        func littleEndian(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        func bigEndian(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }

        guard littleEndian(0) == machHeader64Magic, let commandCount = littleEndian(16) else { return .unknown }
        var commandOffset = 32
        for _ in 0..<commandCount {
            guard let command = littleEndian(commandOffset), let commandSize = littleEndian(commandOffset + 4) else {
                return .unknown
            }
            if command == codeSignatureCommand {
                guard let signature = littleEndian(commandOffset + 8).map(Int.init),
                      bigEndian(signature) == embeddedSignatureMagic,
                      let blobCount = bigEndian(signature + 8) else { return .unknown }
                for index in 0..<Int(blobCount) {
                    guard let slot = bigEndian(signature + 12 + index * 8),
                          let blobOffset = bigEndian(signature + 16 + index * 8) else { return .unknown }
                    let directory = signature + Int(blobOffset)
                    guard slot == 0, bigEndian(directory) == codeDirectoryMagic else { continue }
                    guard let version = bigEndian(directory + 8), version >= teamFieldVersion,
                          let teamOffset = bigEndian(directory + 48), teamOffset != 0 else { return .none }
                    let start = directory + Int(teamOffset)
                    guard start < data.count, let end = data[start...].firstIndex(of: 0) else { return .unknown }
                    return .team(String(decoding: data[start..<end], as: UTF8.self))
                }
                return .unknown
            }
            commandOffset += Int(commandSize)
        }
        return .none
    }
}

/// Reads Ledger's on-disk store, read-only, to confirm what an intent saved.
///
/// Table and column names follow the SwiftData schema (LedgerSchemaV1).
struct LedgerStoreProbe {
    struct ProbeError: Error, CustomStringConvertible {
        let description: String
    }

    /// The newest transaction, with the names of the records it refers to.
    struct Entry: Equatable {
        let kind: String
        let amountMinor: Int64
        let category: String?
        let account: String?
        let destination: String?
        let origin: String?
    }

    let storeURL: URL

    init() throws {
        guard let container = LedgerInstallation.dataContainer() else {
            throw ProbeError(description: "Ledger's data container wasn't found; launch Ledger first")
        }
        storeURL = container.appendingPathComponent("Library/Application Support/Ledger/Ledger.store")
    }

    func transactionCount() throws -> Int {
        try query("SELECT COUNT(*) FROM ZLEDGERTRANSACTION") { statement in
            Int(sqlite3_column_int64(statement, 0))
        } ?? 0
    }

    func newestEntry() throws -> Entry? {
        let sql = """
            SELECT t.ZKINDRAW, t.ZAMOUNTMINOR, c.ZNAME, a.ZNAME, d.ZNAME, t.ZORIGINRAW
            FROM ZLEDGERTRANSACTION t
            LEFT JOIN ZLEDGERCATEGORY c ON t.ZCATEGORY = c.Z_PK
            LEFT JOIN ZACCOUNT a ON t.ZACCOUNT = a.Z_PK
            LEFT JOIN ZACCOUNT d ON t.ZDESTINATIONACCOUNT = d.Z_PK
            ORDER BY t.ZCREATEDAT DESC
            LIMIT 1
            """
        return try query(sql) { statement in
            Entry(
                kind: text(statement, 0) ?? "",
                amountMinor: sqlite3_column_int64(statement, 1),
                category: text(statement, 2),
                account: text(statement, 3),
                destination: text(statement, 4),
                origin: text(statement, 5)
            )
        }
    }

    /// Runs a query and maps its first row, or returns `nil` when there is none.
    private func query<T>(_ sql: String, row: (OpaquePointer) -> T) throws -> T? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw ProbeError(description: "Couldn't open \(storeURL.path)")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ProbeError(description: "Query failed: \(String(cString: sqlite3_errmsg(database)))")
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? row(statement) : nil
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
