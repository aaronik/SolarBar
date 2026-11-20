import Foundation
import SQLite3

/// Local power telemetry only. Never store advertisement keys, packet data or device identifiers.
final class HistoryArchive {
    private var db: OpaquePointer?
    private let copyText = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastPrune = Date.distantPast

    static func source(_ config: ConnectionSettings) -> String? {
        switch config.mode {
        case .demo: nil
        case .bluetooth: "bluetooth"
        case .gx: "gx:\(config.host.lowercased()):\(config.port)"
        }
    }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("history-v1.sqlite").path
        guard sqlite3_open(file, &db) == SQLITE_OK else { throw failure() }
        sqlite3_busy_timeout(db, 250)
        try run("CREATE TABLE IF NOT EXISTS readings (source TEXT NOT NULL, time REAL NOT NULL, data TEXT NOT NULL, PRIMARY KEY(source, time)) WITHOUT ROWID") { _ in }
    }

    deinit { sqlite3_close(db) }

    private func failure() -> NSError {
        NSError(domain: "SolarBar history", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        return stmt
    }

    private func run(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }

    private func prune(at now: Date) throws {
        guard now.timeIntervalSince(lastPrune) >= 600 || now < lastPrune else { return }
        try run("DELETE FROM readings WHERE time < ?") { stmt in
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970 - DashboardHistory.maxAge)
        }
        lastPrune = now
    }

    func append(_ reading: Reading, source: String) throws {
        try prune(at: reading.date)
        let text = String(decoding: try encoder.encode(reading), as: UTF8.self)
        try run("INSERT OR REPLACE INTO readings VALUES (?,?,?)") { stmt in
            sqlite3_bind_text(stmt, 1, source, -1, copyText)
            sqlite3_bind_double(stmt, 2, reading.date.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, text, -1, copyText)
        }
    }

    func load(source: String, at now: Date) throws -> [Reading] {
        try prune(at: now)
        let stmt = try statement("SELECT data FROM readings WHERE source = ? AND time BETWEEN ? AND ? ORDER BY time")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source, -1, copyText)
        sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970 - DashboardHistory.maxAge)
        sqlite3_bind_double(stmt, 3, now.timeIntervalSince1970)
        var readings: [Reading] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                guard let ptr = sqlite3_column_text(stmt, 0) else { continue }
                let data = Data(bytes: ptr, count: Int(sqlite3_column_bytes(stmt, 0)))
                readings.append(try decoder.decode(Reading.self, from: data))
            case SQLITE_DONE: return readings
            default: throw failure()
            }
        }
    }
}
