import Foundation
import WCRIdentity

/// Shared terminal utilities

// MARK: - Escaping helpers

/// Escape a string for interpolation inside an AppleScript double-quoted
/// string literal. Previously each file rolled its own (or skipped it
/// entirely) — this is the single shared implementation.
func escapeForAppleScript(_ string: String) -> String {
    return string
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Escape a string for interpolation inside a double-quoted POSIX shell
/// string (e.g. `cd "<here>"`). Neutralises quote-breakout, command
/// substitution and variable expansion. Used for user-supplied paths like
/// working_directory, which previously went into `cd "…"` unescaped and
/// could break out of the quotes (bypassing the command blocklist).
func escapeForDoubleQuotedShell(_ string: String) -> String {
    return string
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$")
        .replacingOccurrences(of: "`", with: "\\`")
}

/// Marker a generated script touches as its first step, so a background
/// send to Warp can confirm the command actually started.
func startedMarkerPath(forScript scriptPath: String) -> String {
    "\(scriptPath).started"
}

/// Shell line that touches `startedMarkerPath(forScript:)`.
func startedMarkerLine(forScript scriptPath: String) -> String {
    ": > \"\(escapeForDoubleQuotedShell(startedMarkerPath(forScript: scriptPath)))\""
}

/// How long a background Warp send waits for the start marker.
let warpStartTimeout: TimeInterval = 3

/// Create AppleScript for different terminal types. Warp isn't scripted:
/// it's typed into in the background via `WarpBackgroundTyping`.
func createAppleScript(for terminal: TerminalConfig.TerminalType, command: String) -> String {
    // All current callers pass internally-generated commands
    // ("bash /tmp/wcr_script_<uuid>.sh"), but escape regardless so a
    // future caller passing arbitrary text can't break the script.
    let escaped = escapeForAppleScript(command)
    switch terminal {
    case .warp, .warpPreview:
        // Callers branch to WarpBackgroundTyping first; fail loudly if not.
        return "error \"Warp is typed into in the background, not via AppleScript\""

    case .iterm2:
        // Create a new session (tab) for each command
        return """
        tell application "iTerm"
            activate

            if (count of windows) = 0 then
                create window with default profile
            else
                -- Create new tab in current window for isolation
                tell current window
                    create tab with default profile
                end tell
            end if

            tell current window
                tell current session
                    write text "\(escaped)"
                end tell
            end tell
        end tell
        """

    case .terminal:
        // Always open a new tab for command isolation
        return """
        tell application "Terminal"
            activate

            if (count of windows) = 0 then
                do script "\(escaped)"
            else
                -- Open new tab in frontmost window
                tell application "System Events"
                    tell process "Terminal"
                        click menu item "New Tab" of menu "Shell" of menu bar 1
                    end tell
                end tell
                delay 0.5
                do script "\(escaped)" in front window
            end if
        end tell
        """

    case .alacritty:
        // Alacritty doesn't support tabs natively; use keyboard events
        return """
        tell application "Alacritty" to activate
        delay 1.0
        tell application "System Events"
            keystroke "\(escaped)"
            delay 0.2
            keystroke return
        end tell
        """
    }
}

/// Create output capture script
func createOutputCaptureScript(command: String, commandId: String) -> String {
    let outputFile = TempFiles.outputPath(commandId: commandId)
    
    return """
    #!/bin/bash
    umask 077
    \(startedMarkerLine(forScript: TempFiles.scriptPath(commandId: commandId)))
    
    # Command to execute
    COMMAND='\(command.replacingOccurrences(of: "'", with: "'\"'\"'"))'
    
    # Create a temporary file for stderr
    STDERR_FILE="\(TempFiles.stderrPath(commandId: commandId))"
    
    # Execute command and capture output
    OUTPUT=$(eval "$COMMAND" 2>"$STDERR_FILE")
    EXIT_CODE=$?
    
    # Read stderr
    STDERR=$(<"$STDERR_FILE")
    rm -f "$STDERR_FILE"
    
    # Escape JSON strings
    escape_json() {
        python3 -c "import sys, json; print(json.dumps(sys.stdin.read()))" | sed 's/^"//;s/"$//'
    }
    
    # Create JSON result
    cat > "\(outputFile)" << EOF
    {
        "commandId": "\(commandId)",
        "command": "$(echo "$COMMAND" | escape_json)",
        "output": "$(echo "$OUTPUT" | escape_json)",
        "error": "$(echo "$STDERR" | escape_json)",
        "exitCode": $EXIT_CODE,
        "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    }
    EOF
    
    # Signal completion by creating a marker file
    touch "\(outputFile).complete"
    
    # Also echo the output for immediate viewing in terminal
    echo "$OUTPUT"
    if [ -n "$STDERR" ]; then
        echo "$STDERR" >&2
    fi
    
    exit $EXIT_CODE
    """
}
