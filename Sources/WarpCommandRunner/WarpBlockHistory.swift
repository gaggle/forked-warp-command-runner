import Foundation
import SQLite3

// SQLite constants
fileprivate let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only access to the command blocks Warp keeps for session restoration.
///
/// With session restoration on (Warp's default), Warp writes every completed
/// block (command + output) to its own SQLite database, next to the window /
/// tab / pane layout. This reads the most recent blocks of the active tab so an
/// MCP host can see what the user just ran in Warp.
///
/// Warp's schema is internal and may change, so every failure surfaces as a
/// readable `WarpBlockHistoryError` rather than a crash.
///
/// Needs Full Disk Access on the bundle: the database lives in Warp's app group
/// container, which macOS protects as another app's data.
struct WarpBlockHistory {
    static let maxCount = 10
    static let maxOutputLines = 200
    static let maxOutputChars = 16_000

    let databasePath: String

    /// Warp Stable first, then Warp Preview.
    static func locateDatabase() -> String? {
        for terminal in [TerminalConfig.TerminalType.warp, .warpPreview] {
            if let path = TerminalConfig.getWarpDatabasePath(for: terminal) {
                return path
            }
        }
        return nil
    }

    /// The active tab and its most recent executed blocks, oldest first.
    func recentBlocks(count: Int) throws -> (tab: WarpActiveTab, blocks: [WarpBlock]) {
        let db = try ReadOnlyDatabase(path: databasePath)
        let tab = try activeTab(db)
        let blocks = try db.rows(
            """
            SELECT stylized_command, stylized_output, exit_code, pwd,
                   COALESCE(git_branch_name, git_branch), start_ts, completed_ts
            FROM blocks
            WHERE pane_leaf_uuid = ? AND did_execute = 1 AND is_background = 0
            ORDER BY id DESC
            LIMIT ?
            """,
            bind: [.blob(tab.paneUUID), .int(count)]
        ) { row in
            WarpBlock(
                command: Self.plainText(row.data(0)).trimmingCharacters(in: .whitespacesAndNewlines),
                output: Self.plainText(row.data(1)),
                exitCode: row.int(2) ?? 0,
                pwd: row.text(3),
                gitBranch: row.text(4),
                startedAt: row.text(5).flatMap(Self.parseTimestamp),
                completedAt: row.text(6).flatMap(Self.parseTimestamp)
            )
        }
        return (tab, blocks.reversed())
    }

    /// Resolve the active window's active tab and its focused terminal pane.
    private func activeTab(_ db: ReadOnlyDatabase) throws -> WarpActiveTab {
        let recordedWindow = try db.rows(
            "SELECT active_window_id FROM app WHERE active_window_id IS NOT NULL LIMIT 1"
        ) { $0.int(0) }.first ?? nil

        let windows = try db.rows("SELECT id, active_tab_index FROM windows ORDER BY id") {
            (id: $0.int(0) ?? 0, activeTabIndex: $0.int(1) ?? 0)
        }
        let window: (id: Int, activeTabIndex: Int)
        if let recordedWindow, let match = windows.first(where: { $0.id == recordedWindow }) {
            window = match
        } else if windows.count == 1 {
            window = windows[0]
        } else if windows.isEmpty {
            throw WarpBlockHistoryError.noActiveTab
        } else {
            throw WarpBlockHistoryError.ambiguousWindow(count: windows.count)
        }

        let tabs = try db.rows(
            "SELECT id, custom_title FROM tabs WHERE window_id = ? ORDER BY id",
            bind: [.int(window.id)]
        ) { (id: $0.int(0) ?? 0, title: $0.text(1)) }
        guard tabs.indices.contains(window.activeTabIndex) else {
            throw WarpBlockHistoryError.noActiveTab
        }
        let tab = tabs[window.activeTabIndex]

        // Prefer the focused pane; tabs can also hold non-terminal panes,
        // which the join to terminal_panes leaves out.
        let pane = try db.rows(
            """
            SELECT tp.uuid, tp.cwd
            FROM pane_nodes pn
            JOIN pane_leaves pl ON pl.pane_node_id = pn.id
            JOIN terminal_panes tp ON tp.id = pn.id
            WHERE pn.tab_id = ?
            ORDER BY pl.is_focused DESC, tp.is_active DESC, pn.id
            LIMIT 1
            """,
            bind: [.int(tab.id)]
        ) { (uuid: $0.data(0), cwd: $0.text(1)) }.first
        guard let pane, !pane.uuid.isEmpty else {
            throw WarpBlockHistoryError.noActiveTab
        }

        return WarpActiveTab(
            tabIndex: window.activeTabIndex,
            tabCount: tabs.count,
            title: tab.title.flatMap { $0.isEmpty ? nil : $0 },
            cwd: pane.cwd,
            paneUUID: pane.uuid
        )
    }

    // MARK: - Text

    /// Decode a stylized blob and strip terminal control sequences.
    static func plainText(_ data: Data) -> String {
        stripTerminalControls(String(decoding: data, as: UTF8.self))
    }

    /// Remove ANSI/VT escape sequences and resolve carriage returns the way a
    /// terminal would display them (a bare CR rewinds the line, so progress
    /// bars collapse to their final state).
    static func stripTerminalControls(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\u{1B}" {
                i += 1
                guard i < scalars.count else { break }
                switch scalars[i] {
                case "[":
                    // CSI: parameter/intermediate bytes, then one final byte 0x40–0x7E.
                    i += 1
                    while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) { i += 1 }
                    i += 1
                case "]", "P", "X", "^", "_":
                    // OSC / DCS / SOS / PM / APC: until BEL or ST (ESC \).
                    i += 1
                    while i < scalars.count {
                        if scalars[i] == "\u{07}" { i += 1; break }
                        if scalars[i] == "\u{1B}", i + 1 < scalars.count, scalars[i + 1] == "\\" { i += 2; break }
                        i += 1
                    }
                case "(", ")", "*", "+":
                    // Character set designation: one more byte.
                    i += 2
                default:
                    i += 1
                }
                continue
            }
            let isDroppedControl = (c.value < 0x20 && c != "\n" && c != "\r" && c != "\t") || c.value == 0x7F
            if !isDroppedControl {
                out.append(c)
            }
            i += 1
        }

        return String(out)
            .components(separatedBy: "\n")
            .map { line -> String in
                var rest = Substring(line)
                while rest.hasSuffix("\r") { rest = rest.dropLast() }
                if let lastCR = rest.lastIndex(of: "\r") {
                    rest = rest[rest.index(after: lastCR)...]
                }
                return String(rest)
            }
            .joined(separator: "\n")
    }

    /// Keep the end of the output, where errors usually are.
    static func tail(_ text: String, maxLines: Int, maxChars: Int) -> (text: String, omittedLines: Int) {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        let total = lines.count
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }
        var kept = lines.joined(separator: "\n")
        if kept.count > maxChars {
            kept = String(kept.suffix(maxChars))
            if let firstNewline = kept.firstIndex(of: "\n") {
                kept = String(kept[kept.index(after: firstNewline)...])
            }
        }
        let keptLines = kept.isEmpty ? 0 : kept.components(separatedBy: "\n").count
        return (kept, total - keptLines)
    }

    // MARK: - Timestamps

    private static let timestampFormatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss.SSSSSS",
        "yyyy-MM-dd HH:mm:ss",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    /// Warp stores UTC timestamps as `yyyy-MM-dd HH:mm:ss.ffffff`.
    static func parseTimestamp(_ value: String) -> Date? {
        for formatter in timestampFormatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    // MARK: - Rendering

    static func render(tab: WarpActiveTab, blocks: [WarpBlock], now: Date) -> String {
        let title = tab.title.map { "\"\($0)\"" } ?? "untitled"
        var out = "Warp active tab: \(tab.tabIndex + 1) of \(tab.tabCount), \(title)"
        if let cwd = tab.cwd {
            out += ", \(abbreviateHome(cwd))"
        }
        out += "\n"

        if blocks.isEmpty {
            out += "\nNo completed commands in this tab yet. Warp only records a command once it finishes."
            return out
        }

        out += "Last \(blocks.count) command\(blocks.count == 1 ? "" : "s"), oldest first. Terminal styling removed.\n"
        for (index, block) in blocks.enumerated() {
            out += "\n[\(index + 1)] $ \(block.command)\n"
            var facts = ["exit \(block.exitCode)"]
            if let started = block.startedAt {
                facts.append("\(localTime(started)) (\(ago(started, now: now)))")
                if let completed = block.completedAt {
                    facts.append("took \(duration(completed.timeIntervalSince(started)))")
                }
            }
            if let pwd = block.pwd {
                facts.append(abbreviateHome(pwd))
            }
            if let branch = block.gitBranch, !branch.isEmpty {
                facts.append("git \(branch)")
            }
            out += "    " + facts.joined(separator: " · ") + "\n"

            let output = tail(block.output, maxLines: maxOutputLines, maxChars: maxOutputChars)
            if output.omittedLines > 0 {
                out += "[\(output.omittedLines) earlier output lines omitted]\n"
            }
            out += output.text.isEmpty ? "(no output)\n" : output.text + "\n"
        }
        return out
    }

    private static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static func localTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss xxx"
        return formatter.string(from: date)
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? String(format: "%.1fs", seconds) : "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }
}

struct WarpBlock: Equatable {
    let command: String
    let output: String
    let exitCode: Int
    let pwd: String?
    let gitBranch: String?
    let startedAt: Date?
    let completedAt: Date?
}

struct WarpActiveTab: Equatable {
    /// 0-based position within the window.
    let tabIndex: Int
    let tabCount: Int
    let title: String?
    let cwd: String?
    let paneUUID: Data
}

enum WarpBlockHistoryError: Error, CustomStringConvertible {
    case databaseNotFound
    case cannotOpen(String)
    case ambiguousWindow(count: Int)
    case noActiveTab
    case query(String)

    var description: String {
        switch self {
        case .databaseNotFound:
            return """
            Warp's database (warp.sqlite) was not found, or macOS blocked access to it.
            Check that Warp is installed with session restoration on, and that Warp Command Runner has Full Disk Access (System Settings → Privacy & Security → Full Disk Access).
            """
        case .cannotOpen(let message):
            return """
            Could not open Warp's database read-only: \(message)
            If this says "authorization denied", grant Full Disk Access to Warp Command Runner (System Settings → Privacy & Security → Full Disk Access) and restart your MCP host.
            """
        case .ambiguousWindow(let count):
            return "Warp has \(count) windows open and did not record which one is active. Close the extra windows, or switch to the tab you mean and try again."
        case .noActiveTab:
            return "Could not find the active Warp tab in Warp's saved layout. Is a terminal tab open?"
        case .query(let message):
            return "Reading Warp's database failed: \(message). Warp's internal schema may have changed."
        }
    }
}

// MARK: - Minimal read-only SQLite access

private final class ReadOnlyDatabase {
    enum Binding {
        case int(Int)
        case blob(Data)
    }

    struct Row {
        let statement: OpaquePointer

        func int(_ column: Int32) -> Int? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
        }

        func text(_ column: Int32) -> String? {
            guard let cString = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: cString)
        }

        func data(_ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    private var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            db = nil
            throw WarpBlockHistoryError.cannotOpen(message)
        }
        // Warp writes in WAL mode; readers don't block, but be patient with checkpoints.
        sqlite3_busy_timeout(db, 1_000)
    }

    deinit {
        sqlite3_close(db)
    }

    func rows<T>(_ sql: String, bind bindings: [Binding] = [], _ map: (Row) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WarpBlockHistoryError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .int(let value):
                sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case .blob(let value):
                _ = value.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
            }
        }

        var results: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                results.append(try map(Row(statement: statement)))
            } else if step == SQLITE_DONE {
                return results
            } else {
                throw WarpBlockHistoryError.query(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}
