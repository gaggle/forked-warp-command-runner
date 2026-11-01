import Foundation
import Logging
#if canImport(AppKit)
import AppKit
import ApplicationServices
#endif

/// Types into Warp without bringing it to the front.
///
/// The old path ran `tell application "Warp" to activate` and then System
/// Events `keystroke`, which stole focus and mixed whatever the user was
/// typing into Warp's input. This posts key events to Warp's process only
/// (`CGEvent.postToPid`) from a private event source, so the front app and
/// the user's own modifier keys are left alone.
///
/// Warp drops posted keys while its window isn't main (seen after a
/// minimize/restore or hide/unhide), and a dropped send looks the same as a
/// good one to the sender. So each send first marks Warp's window as main
/// through Accessibility, which un-minimizes/un-hides it *behind* the front
/// window, and callers verify that the command actually started.
enum WarpBackgroundTyping {

    /// One key event pair (down + up) to post.
    enum Key: Equatable {
        /// A single UTF-16 code unit, sent as the event's unicode string.
        case unit(UInt16)
        /// Return (virtual key 36).
        case returnKey
    }

    static let returnVirtualKey: UInt16 = 36

    /// How long a send waits for this server's previous Warp command to exit.
    static let previousCommandTimeout: TimeInterval = 10

    /// Done marker of the last script this server typed into Warp. Keys sent
    /// while it still runs would be echoed into its output and queued in the
    /// tty, so the next send waits for it.
    private actor PreviousCommand {
        var donePath: String?
        func set(_ path: String?) { donePath = path }
        func clear(ifEqual path: String) { if donePath == path { donePath = nil } }
    }
    private static let previous = PreviousCommand()

    /// The keys that type `text`, one event per UTF-16 unit, then Return.
    static func keys(for text: String, pressReturn: Bool = true) -> [Key] {
        var keys = text.utf16.map(Key.unit)
        if pressReturn { keys.append(.returnKey) }
        return keys
    }

    /// Type `command` into the focused pane of Warp's main window and press
    /// Return, without activating Warp. Waits for the previous script this
    /// server sent to exit first. Pass `scriptPath` when `command` runs a
    /// generated script, so the next send can wait for it in turn.
    @discardableResult
    static func type(
        _ command: String,
        into terminal: TerminalConfig.TerminalType,
        scriptPath: String? = nil,
        logger: Logger
    ) async -> (success: Bool, error: String?) {
        #if canImport(AppKit)
        if let done = await previous.donePath {
            guard await waitForFile(done, timeout: previousCommandTimeout) else {
                return (false, "The previous command this server sent to \(terminal.rawValue) is still running after \(Int(previousCommandTimeout))s. Wait for it to finish (get_command_output), or stop it in Warp, then retry.")
            }
            // Give the shell a moment to get back to its prompt.
            try? await Task.sleep(nanoseconds: 300_000_000)
            await previous.set(nil)
        }
        guard AXIsProcessTrusted() else {
            return (false, "Accessibility permission is missing for this binary. Grant it in System Settings > Privacy & Security > Accessibility.")
        }
        guard let pid = runningPid(for: terminal) else {
            return (false, "\(terminal.rawValue) isn't running. Open it first; commands are no longer sent by launching it to the front.")
        }

        markMainWindow(pid: pid, logger: logger)

        let source = CGEventSource(stateID: .privateState)
        for key in keys(for: command) {
            if key == .returnKey {
                // Let Warp's input settle before submitting (the old
                // AppleScript path waited 0.2s here too).
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard post(key, to: pid, source: source) else {
                return (false, "Couldn't create a keyboard event for \(terminal.rawValue).")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if let scriptPath { await previous.set(doneMarkerPath(forScript: scriptPath)) }
        logger.debug("typed \(command.utf16.count) units into \(terminal.rawValue) (pid \(pid)) in the background")
        return (true, nil)
        #else
        return (false, "Typing into \(terminal.rawValue) needs macOS.")
        #endif
    }

    /// Poll for `path` to exist. Callers point this at a marker the typed
    /// command writes as its first step, to tell a command that ran from
    /// keys that were dropped or went to a busy tab's running process.
    static func waitForFile(
        _ path: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1,
        fileManager: FileManager = .default
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if fileManager.fileExists(atPath: path) { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    /// Wait for a generated script's start marker. On timeout, delete the
    /// script: keys typed into a busy tab sit in the tty buffer and the shell
    /// runs them once the tab is free, so without this a send reported as
    /// failed would still run later. Re-checks the marker after deleting in
    /// case the script started at the last moment.
    static func confirmStartOrDisarm(
        scriptPath: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1,
        fileManager: FileManager = .default
    ) async -> Bool {
        let marker = startedMarkerPath(forScript: scriptPath)
        if await waitForFile(marker, timeout: timeout, pollInterval: pollInterval, fileManager: fileManager) {
            return true
        }
        try? fileManager.removeItem(atPath: scriptPath)
        if fileManager.fileExists(atPath: marker) { return true }
        // A cancelled script never writes its done marker; don't make the
        // next send wait for it.
        await previous.clear(ifEqual: doneMarkerPath(forScript: scriptPath))
        return false
    }

    /// Error text for a send whose start marker never appeared.
    static func notStartedMessage(terminal: TerminalConfig.TerminalType, waited: TimeInterval) -> String {
        """
        ❌ \(terminal.rawValue) didn't start the command within \(Int(waited))s, so it was cancelled.
        Usually the active tab is still running something, and the keys went to that process. \
        When it finishes, the shell will run the typed line and print "No such file or directory" \
        for the deleted script; the command itself won't run. Check the active Warp tab before retrying.
        """
    }

    /// Error text for a `send_to_session` the shell shim never saw start.
    static func notConfirmedMessage(terminal: TerminalConfig.TerminalType, waited: TimeInterval) -> String {
        """
        ❌ \(terminal.rawValue) didn't start the command within \(Int(waited))s.
        Usually the active tab is still running something. The keys went to that process, and \
        the shell may still run the command once it finishes. Check the active Warp tab before retrying.
        """
    }

    #if canImport(AppKit)
    private static func runningPid(for terminal: TerminalConfig.TerminalType) -> pid_t? {
        for bundleId in TerminalConfig.getBundleIdentifiers(for: terminal) {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                return app.processIdentifier
            }
        }
        return nil
    }

    /// Make Warp's first window its main window. Best effort: AX can't see a
    /// window on another Space, but there Warp still takes keys while the
    /// window remains main, and the caller's verification catches the rest.
    private static func markMainWindow(pid: pid_t, logger: Logger) {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], let window = windows.first else {
            logger.debug("no AX-visible Warp window; typing without setting AXMain")
            return
        }
        let status = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        if status != .success {
            logger.debug("setting AXMain on Warp's window failed (AXError \(status.rawValue))")
        }
    }

    private static func post(_ key: Key, to pid: pid_t, source: CGEventSource?) -> Bool {
        let virtualKey: CGKeyCode = key == .returnKey ? returnVirtualKey : 0
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            return false
        }
        if case .unit(var unit) = key {
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        }
        // No modifiers, whatever the user is holding: a held Cmd would
        // otherwise turn typed letters into Warp shortcuts (Cmd+W closes).
        down.flags = []
        up.flags = []
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
    #endif
}
