# Ideas

Planning for this fork. Lives on the fork's `work` branch only; never cherry-pick it into an
upstream PR branch.
NOW is the next story in detail, SOON are outcome-level epics, LATER is a loose list.
Move items into project management when they're picked up.

Driving use case: "I ran something in Warp, it broke. Claude, what gives?"

## NOW: Ship `get_recent_warp_blocks` upstream

**Why.** The narrowest useful slice works end to end (Claude Desktop read a real failing `ls /foo`,
exit 2). Getting it in front of the maintainer now gives feedback on direction and conventions before
we broaden anything.

**Starting point.** Branch `feat/warp-block-history`, 3 commits on top of `43944d7`:

1. `3ff91a4` Find Warp's database in its app group container.
2. `4322abf` Add a read-only reader for Warp's block history.
3. `e95e2b2` Add get_recent_warp_blocks tool for the active Warp tab.

54 tests green. The release build, stdio proof (41 tools), HTTP proof and version check all pass.

**Done when.**

- The active-tab assumptions are verified on real Warp, or their limits are stated in the tool
  description and README.
- Docs match the binary (AGENTS.md: "Done means the verification gate is green, docs match the binary").
- The full verification gate is green, with summary lines quoted.
- A PR is open from a fork, with the description points below.

**Steps.**

1. **Freshness of the active tab.** Blocks are saved as they complete, but `windows.active_tab_index`
   is part of Warp's layout snapshot. In Warp: run `echo one` in tab A, switch to tab B without running
   anything, then call the tool.
   - Expect tab B's title, cwd and last command.
   - If it still shows tab A, time how long Warp takes to save. If it's more than a second or two, say
     "may lag briefly after switching tabs" in the tool description.
2. **Tab order.** The tool assumes `tabs` ordered by `id` matches what `active_tab_index` counts.
   Reorder a tab by dragging, and move one between tab groups. Check that "tab N of M" and the content
   match what's on screen after each change.
3. **Multiple windows.** Open a second Warp window and call the tool. Expect the "Warp has 2 windows
   open..." refusal. Note whether `app.active_window_id` gets populated. If it does, add a test for it.
   Today `testUsesRecordedActiveWindow` assumes the column is used.
4. **Docs.**
   - README tool table: add a "Warp block history" table (or a row under "Warp v6.0 — deeplinks,
     OSC 777, shell shim") for `get_recent_warp_blocks`.
   - Tool counts: "40"/"Forty" → 41 and "34" → 35. There are 10 mentions in README, plus AGENTS.md
     gate step 3 ("tools/list → 40 tools").
   - CHANGELOG: entry under `[Unreleased]`. No version bump (the maintainer's call; the gate requires
     `AppIdentity.version`, CHANGELOG and README to agree).
   - README's Sequoia recipe: one line saying Full Disk Access also lets the server read Warp's history.
5. **Gate.** Run all five steps from AGENTS.md:
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` for step 1, and
   `./examples/run_test.sh` / `./examples/run_http_test.sh` against `.build/release/warp-command-runner`.
6. **Fork and PR.** Ask before pushing or opening the PR. `origin` is M-Pineapple's repo, so:
   `gh repo fork M-Pineapple/warp-command-runner --remote --remote-name fork`, push the branch to
   `fork`, then open the PR against `M-Pineapple:main`. Keep commits atomic and in the repo's message
   style (plain imperative sentence ending with a period).
7. **PR description points.**
   - Needs Full Disk Access on the bundle, because Warp's data lives in its app group container (App
     Data protection). This is already part of the Sequoia recipe.
   - Warp's schema is internal; failures surface as readable errors, not crashes.
   - `TerminalConfig.getWarpDatabasePath` pointed at Warp's old location and had no callers; this fixes
     and reuses it.
   - Ask about remote policy: the tool isn't gated for `--http` callers, since they can already run
     anything through `execute_pipeline`. Would the maintainer prefer gating terminal history anyway?
   - Mention it's the first of small increments (see SOON) and ask whether that direction is welcome.

## NOW: Type into Warp without bringing it to the front

**Why.** Every keystroke tool activates Warp before typing (`tell application "Warp" to activate`,
then System Events `keystroke`). Warp jumps in front, and whatever you're typing lands in Warp's
input along with the command. You can't work while a process drives Warp.

**Approach (tested 2026-11-01, see facts below).** Don't activate Warp, and don't use System Events.

1. Make Warp's window its main window through Accessibility:
   `set value of attribute "AXMain" of window 1 to true` on process `stable`.
2. Post the keystrokes to Warp's process only: `CGEvent` with `keyboardSetUnicodeString`, one event
   per UTF-16 unit, sent with `postToPid(warpPid)` from a `CGEventSource(stateID: .privateState)`.
   Return is virtual key 36.
3. Wait until the previous command has finished before typing. Then confirm the new one ran, using
   the shell shim's `command_finished` event or `get_recent_warp_blocks`.

**Where it changes.** Every Warp branch that activates and types:

- `keystrokeSendToCurrentTab` (`TerminalSessions.swift`), used by `send_to_session` and the `cd`
  after a new tab.
- The Warp branch of `createAppleScript` (`TerminalUtilities.swift`), used by `execute_command` and
  similar.
- `newTabAppleScript` / `closeTabAppleScript` for Warp click menu items after activating. Check
  whether `AXPress` on the menu item works without activating.
- `open warp://…` (new tab, focus session) activates Warp as a side effect. `open -g` kept a launch
  config in the background (see facts); untested for `warp://action/new_tab`.

**Done when.**

- No Warp keystroke tool activates Warp. Checked with the front app before and after each call.
- Typing in another app during a tool call loses nothing on either side.
- A command that didn't run is reported as an error, not success.
- The verification gate is green, and the docs describe the new behaviour.

**Facts from the 2026-11-01 tests.** Prototype: a Swift CLI posting to Warp's PID, with one Warp
window open. Each send was verified via block history or a marker file. Claude (or TextEdit) stayed the front
app in every case.

| Case | Result |
|---|---|
| 20 commands with spaces, double spaces, quotes, `$HOME`, `ü→`, `bash /tmp/wcr_script_N.sh`; 5 ms and 0 ms between keys | All byte-for-byte exact |
| User holding Shift or Option during the send | Ignored: text exact, Return still runs the command. Cmd untested (could fire Warp shortcuts like Cmd+W) |
| Ctrl+C (virtual key 8 with `.maskControl`) | Works; ended a stuck `quote>` prompt with exit 130 |
| User typing in TextEdit while 10 commands were sent | All 10 exact; the user's text intact; TextEdit kept focus |
| Warp minimized or hidden, without `AXMain` | Keys silently dropped. Not buffered: nothing appeared later |
| Warp minimized, with `AXMain` | Works. Window un-minimizes **behind** the front window, without taking focus |
| Warp hidden (Cmd+H), with `AXMain` | Works. Warp un-hides behind the front window |
| Warp on another Space | Works without `AXMain` while the window is still main. AX can't see the window from another Space |
| Warp minimized and on another Space, with `AXMain` | Works. AX can see minimized windows; Warp restores onto its own Space and the user stays put |
| Screen locked (front app `loginwindow`) | Works |
| Typing the next command while the previous one still runs | Breaks: keys go to the running process. Produced `shift-cle'ar` and a stuck `quote>` |

More facts:

- After a minimize/restore or hide/unhide, Warp's window had `AXMain = false` (`AXFocused = true`),
  and that alone made Warp drop every key. Setting `AXMain` again fixed it without activating Warp.
- Without the fix, a dropped send looks the same as a successful one to the sender. Verification
  is required, not optional.
- The typing-while-busy race is a likely cause of the dropped-space bug (`bash/tmp/wcr_script_<id>.sh`,
  exit 127). Unconfirmed.
- Bundle ID `dev.warp.Warp-Stable`, process name `stable`. Warp Preview's IDs are unchecked.
- Launch configs: `open -g "warp://launch/<name>"` (name, not path; file in
  `~/.warp/launch_configurations/`) ran the config's `commands` without activating Warp, but opens a
  new window every time. The path form did nothing. Better suited to "open a workspace" than to
  routine commands.

## SOON

### Tab awareness

**Outcome:** Claude can see which tabs exist and read any of them, not just the active one.
Covers `list_tabs` (titles, cwd, tab groups, active marker) and a `tab` parameter on
`get_recent_warp_blocks`. Split panes within a tab come into it too, since today we take the
focused terminal pane. For Warp users this could replace `list_sessions`, which only knows tabs
warp-command-runner opened itself. The data is all in `windows`, `tabs`, `pane_nodes`,
`pane_leaves` and `terminal_panes`, joined to `blocks` on the pane UUID.

### Setup diagnostics

**Outcome:** setup problems show up before the first "what gives?". `self_check` reports whether
Warp's database was found and is readable, and points to Full Disk Access when it isn't.

### Safer keystroke tools

**Outcome:** you always know which tab a typed command went to. Today they type into whatever has
focus. Use the active-tab data to report the receiving tab (title, cwd), or to refuse when it isn't
the tab the caller expected.

### Upstream doc fixes (separate small PR)

**Outcome:** the next person sets this up without our detours.

- `~/Applications` works as an install location; the README says `/Applications` is required.
- Claude Desktop rewrites `claude_desktop_config.json` from memory while running, so edit it only
  while the app is quit.
- Quick Install step 3 says to add the bare `.build` binary to Accessibility and re-add it after
  every rebuild. With the signed bundle, grants persist.
- `execute_pipeline` truncates each step's output to ~1KB.
- Explain the tools in "Warp is just a terminal" terms: sessions and workspace profiles are labels in
  warp-command-runner's own storage, not Warp tabs, and keystroke tools always hit the focused tab.

### Shutdown signal bug

**Outcome:** hosts can stop the server cleanly. It ignores SIGTERM and SIGINT while its stdin stays
open (seen from Claude Desktop, and `claude -p` logs "SIGINT failed, sending SIGTERM"), so hosts
fall back to SIGKILL. Report it upstream first; fix if welcome.

## LATER

- History from closed tabs (800 of 956 blocks belonged to panes that no longer exist).
- Search Warp's `commands` table (~10k rows: exit code, pwd, git branch, session, timestamps), e.g.
  "when did this last pass?".
- Map warp-command-runner's own blocks (`bash /tmp/wcr_...` wrappers) back to the original command.
- Type into a background tab: focus it via `warp://session/<uuid>` with the pane UUID from the DB,
  then type. Unknown whether Warp's deeplink accepts that UUID.
- A real "active window" signal for multi-window setups, if `app.active_window_id` stays NULL.
- Explicit schema checks (expected columns present) beyond today's generic "schema may have changed".
- Gate terminal-history tools for `--http` callers, if upstream wants it.

## What's happened

### Timeline

- **2026-10-10, Phase 1:** cloned v8.0.0 unchanged and built it signed with the existing Apple
  Development cert. Installed it in `~/Applications`, registered it in Claude Desktop, granted Full
  Disk Access, Input Monitoring and Accessibility. All keystroke tools verified in Warp.
- **2026-10-10/11, Phase 2 step 1:** explored Warp's database, built `get_recent_warp_blocks`, and
  verified it from Claude Desktop with a real failing command.

### Do

- **Sync with upstream with `./sync-upstream`.** It fast-forwards `main` to `upstream/main`, pushes
  it, rebases `work` onto it and force-pushes `work`. Like IDEAS.md, it lives on `work` only.

- **Edit `claude_desktop_config.json` only while Claude Desktop is quit.** It rewrites the file from its
  in-memory copy a few seconds after chat activity, silently dropping outside edits. After editing,
  check the file again a few minutes later, not just straight away.
- **Reload a new binary with stop + toggle:**
  `kill -9 $(pgrep -f "Warp Command Runner.app/Contents/MacOS/warp-command-runner$")`, then toggle the
  connector off and on. Run it from a normal terminal (`pgrep` can't see other processes from Claude
  Code's sandbox; use `ps` there).
- **Build signed:** export `WCR_CODESIGN_IDENTITY` (Apple Development cert SHA-1) from the shell
  profile, and open a new shell before `./build.sh`. TCC matches bundle ID + certificate name, not the
  build hash, so grants survive rebuilds. When the cert expires, renew it in Xcode > Settings >
  Accounts, keeping the same name.
- **Install:** `rm -rf ~/Applications/"Warp Command Runner.app" && cp -R .build/release/warp-command-runner.app ~/Applications/"Warp Command Runner.app"`
  (`rm` first, or `cp -R` nests the bundle).
- **Run tests with Xcode's toolchain:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
  XCTest isn't in Command Line Tools. Opening Xcode accepted its license.
- **Read Warp's data through the server, or a child of it.** `execute_pipeline` children inherit the
  bundle's Full Disk Access, which is also how to try a new build against real data before installing.
- **Write `execute_pipeline` results to a file and read that.** Step output is truncated at ~1KB.
- **Use Apple's Swift toolchain.** It's current (6.4); nixpkgs had 6.2.4, and devenv would add a second
  toolchain to an upstream fork.

### Don't

- **Don't toggle a running server and expect a reload.** It only hides and shows its tools.
- **Don't rely on SIGTERM to stop it.** It's ignored while connected.
- **Don't read `warp.sqlite` from Claude Code or a plain shell.** macOS denies it ("authorization
  denied") and a CLI can't show the permission prompt.
- **Don't judge data size from truncated output.** A cut-off query made 956 blocks look like 3.
- **Don't run bare `xcodebuild`** while Command Line Tools is the active developer dir. It fails; use
  the full path under `/Applications/Xcode.app/Contents/Developer/usr/bin/` or `xcode-select -s`.
- **Don't parse `ls` output in scripts.** `ls` may be aliased (eza, for example, quotes paths). Use
  globs or `command ls`.

### Lessons about Warp's data

- Location: `~/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite`
  (WAL mode; read-only access works while Warp runs).
- `stylized_command` / `stylized_output` are BLOBs with ANSI styling, even bold around every single
  character of the command. Output lines end in `\r\n`. Timestamps are UTC text.
- Skip `did_execute = 0` and `is_background = 1` rows.
- `terminal_panes.uuid` = `blocks.pane_leaf_uuid` links tabs to their blocks. `block_id` looks like
  `precmd-<shell session>-<n>`, which tells shell sessions apart.
- `app.active_window_id` was NULL with one window open.
- The `commands` table is separate from `blocks` and holds ~10k rows of history.
