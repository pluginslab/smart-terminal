# Changelog

## [0.12.0] - 2026-11-06
- New: `claude-sessions.json` in Smart Terminal's Application Support folder, for tools outside the app (the Mobile Agent bridge shows it in its sessions list). For every tab: its name, its group's name and colour, the window, the folder, and the Claude Code session running or saved in it; keyed by Claude session id and by tab id. Rewritten in one step whenever any of that changes, readable only by you; `pid` says which Smart Terminal wrote it, so a file left by one that quit can be told apart. A Claude Code hook can name its tab exactly from `SMART_TERMINAL_TAB` (except inside tmux, where it names the tab that started the tmux server).

## [0.11.3] - 2026-11-06
- Fix: going back to a group in the sidebar showed its first session, not the one you had open there. Each group (and Ungrouped, and All Sessions) now remembers the session last shown in it and shows it again; the first one only if that session was closed or moved. Kept while the app runs, not across launches.

## [0.11.2] - 2026-11-05
- Fix: "Sign in with Google" and other OAuth popups hung on their last screen. A page's `window.open` loaded in the pane itself, so the sign-in had no `window.opener` to hand its result to and no popup to close. Popups a page opens now get a real window over the app's (with the configuration WebKit hands over, which keeps the opener); `window.close()` closes it. Links with `target="_blank"` still load in the pane. WebKit panes only: Chromium panes are unchanged.
- Smart Terminal declares that it opens `http`/`https` links. That makes it a browser to macOS, a condition for Apple's passkey entitlement (`com.apple.developer.web-browser.public-key-credential`), which would let the pane use passkeys from the Passwords app; it is not granted yet. It doesn't become your default browser unless you choose it; if you do, links open in the browser of the tab in front.

## [0.11.1] - 2026-11-04
- Agents' pages get a desktop layout in a narrow pane. They took the pane's width (about 560 px), so sites handed agents their phone layout. An agent's page is now zoomed out with Chromium's own page zoom until the pane holds 1366 CSS pixels, applied again after each navigation. Input stays Chromium's, so clicks land right for the agent and for you. Your own panes aren't zoomed.
- Restored sessions resume when you open their tab, one at a time as you get to them, instead of all at once through Resume All (30 Claude sessions starting together pinned the CPU). The tab in front of each window resumes at launch; the others wait with their Resume bar until you look at them. Shell ▸ Resume Sessions When Opened turns it off; Resume All Sessions still starts every one.

## [0.11.0] - 2026-11-04
- New: agents get a browser in their tab. [devtools-fleet-mcp](https://github.com/pluginslab/devtools-fleet-mcp) run in a tab (0.2.0 and later) uses the tab's pane instead of launching Chrome, with chrome-devtools-mcp's tools unchanged: navigation, snapshots, input, screenshots, console, network, performance traces, Lighthouse. The pane runs Chromium (CEF 156, via a vendored [CefSwift](https://github.com/Rajaniraiyn/CefSwift)) as a native view, started on first use. It shows an **Agent** badge and, with several pages, a page menu; pages off screen keep rendering.
- The agent browser gate: a local endpoint (127.0.0.1, token in a 0600 `chromium-gate.json`, path in `SMART_TERMINAL_GATE`) that hands a tool a browser in a tab. Each connection runs through a filter on the DevTools protocol: its own in-memory profile and targets only, cookies through its own pages, an allowlist of browser-wide commands, new pages opened in the pane, everything a client set up undone when it goes. Chromium has no debugging port: the app reaches it over a pipe. Details in SECURITY.md.
- View ▸ Browser Engine: WebKit (default) or Chromium for the panes you open.
- New: **Copy Claude Session ID** and **Copy Claude Session Reference** in a tab's context menu. The reference is a line to paste into another session's prompt: the session's title, ID and transcript path, so Claude reads that session instead of searching for it.
- Fix: a page calling `window.close()` could have closed the window it sat in. Embedded browsers now leave windows alone; the page leaves the pane.
- The app is larger: about 610 MB, almost all of it Chromium for both architectures.

## [0.10.2] - 2026-11-03
- Fix: Slack (and other sites that sniff for a supported browser) turned the browser pane away with "your browser is not supported". A bare `WKWebView` sends Safari's user agent without its `Version/… Safari/…` tail. It now adds that (`applicationNameForUserAgent`), with the version of the Safari installed on the Mac.
- Fix: a Smart Terminal started from one of its own tabs (`open -a`, a dev build, `scripts/dev-run.sh`) filled its shells with "job table full or recursion limit exceeded". It inherited that tab's `ZDOTDIR`, took the shim folder for the user's own, and the startup files sourced each other until zsh gave up. The app now passes on the folder the shim stood in for, never a shim (it marks its folder with `.smart-terminal-shim`, and recognises 0.10.0's by their header), and `.zshenv` falls back to `$HOME` if it is ever pointed at one.

## [0.10.1] - 2026-10-29
- Docs only: a screenshot of the browser pane in the README's Browser section, taken by `scripts/demo-screenshot.sh` with its new `DEMO_BROWSER=<url>` (and `DEMO_OUT=<png>`) option, which opens that page in the Claude tab's browser in a wider window. The app is unchanged from 0.10.0.

## [0.10.0] - 2026-10-29
- New: a browser per tab, in a pane beside its terminal. Back, forward, reload or stop, an address bar (URL, host or search), open in the default browser, close, and the Web Inspector (hammer, `⌥⌘I`, or *Inspect Element*). WebKit, with each tab's page, history and pane width kept across tab switches; site data shared and persistent.
- `open https://…` in a tab shows the page there, including from Claude Code's Bash tool. zsh shell integration in the VS Code style: `ZDOTDIR` points at startup files in Application Support that source yours unchanged and define `open`, which drops a single web URL in an inbox folder the app watches and passes anything else to `command open`. `ZDOTDIR` stays set for child shells, which is how Claude's tool shell (a fresh zsh it snapshots) gets it. Inside tmux the tab id is the server's, so none is sent and the page opens in the tab in front. A request older than a minute (left over from before a restart) is dropped.
- ⌘-clicking a web link in the terminal opens it in the tab's browser (`requestOpenLink`); other links still go to macOS.
- A globe next to the sidebar button (and View → Show Browser, `⇧⌘B`) shows or hides the tab's browser; with none yet, an empty one opens with the address field focused. Hiding keeps the page; the pane's × closes it.
- Links that open a new window (`target="_blank"`, `window.open`) load in the same pane, so they join its history.
- Address and inbox parsing in `SmartTerminalCore` (`BrowserAddress`, `BrowserRequest`), with tests.

## [0.9.4] - 2026-10-29
- The groups sidebar runs the full height of the window, with the traffic lights inside it, as in Mail. macOS only draws a sidebar that way when the window has a toolbar, so columns mode now has one, holding a single item: the standard sidebar toggle at the sidebar's top right, which collapses the groups column. With the column collapsed, the session header moves right to clear the traffic lights and the toggle. It reads that from where the column sits, because the toolbar's toggle doesn't update SwiftUI's column visibility.
- README screenshot retaken.

## [0.9.3] - 2026-10-29
- Fix: a tab could spin its Claude asterisk forever while Claude sat idle. Claude Code can park a session into a background job (`parkedJobId` in `~/.claude/sessions/<pid>.json`), and from then on it stops updating that file, so its `status` stays frozen at `busy`. The file always beat the title glyph, so the frozen `busy` won over Claude's own live `✳`. Now a `busy` file gives way to an idle title when the file is parked or its status hasn't changed for 10 minutes. A working turn keeps the title spinning, `waiting` still comes only from the file, and a long `!` command (`shell`) still counts as work.

## [0.9.2] - 2026-10-29
- The groups column starts right under the traffic lights again. It had the session list's header height as top padding, meant to line *All Sessions* up with the first session row, which left an empty band above it. Only the session list keeps a gap below its header.

## [0.9.1] - 2026-10-29
- Moving a tab within its group is now `⌃⌥←` / `⌃⌥→` only. Plain `⌃←` / `⌃→` are macOS's "Move left/right a space", so the app either never saw them or, with those turned off to let it, took Spaces switching away. They were the menu's shortcut, with `⌃⌥` as a hidden alias; now `⌃⌥` is the one shown and `⌃` is free for Mission Control.

## [0.9.0] - 2026-10-28
- New default layout, in columns like Mail: groups on the left (*All Sessions*, each group with its tab count and an orange dot when a session in it needs you, *Ungrouped*), the group's sessions in the middle, the terminal on the right. The content runs up under a transparent title bar, with a header over each column at traffic-light height. The Chrome-style strip is still there: View → Tabs in Columns (`⌃⌘L`).
- Each session row shows its git state: branch, ahead/behind, and the uncommitted diff as `+12 −4` (`?N` untracked, a check when clean). `git status --porcelain=v2 --branch` and `git diff --shortstat HEAD` run once per folder, every 4 s while the list is on screen, with `GIT_OPTIONAL_LOCKS=0` so they never take the index lock. Parsing lives in `SmartTerminalCore.GitStatus`, with tests.
- The sidebar's Claude pane is replaced by a status bar under the terminal: Claude's status and running subagents on the left, model, context (ring and `232k / 1M`) and token total on the right; clicking it opens the session cards. Without Claude it shows folder, command and size, so it never appears or disappears and resizes the grid. The sidebar is now the clipboard history alone.
- Rows and group entries in the columns are plain views with their own click handling, not `List` selection: `List`'s click handling fought the rows' drag and double-click handlers, so a click only selected when it landed just right.
- The 0.8.4 ring fix carries over to the status bar (`.id(tab.id)`), which follows the active tab the same way the pane did.

## [0.8.4] - 2026-10-21
- Fix: switching tabs made the sidebar's context ring sweep from the previous tab's value to the new one. The Claude pane follows the active tab, so to SwiftUI a tab switch looked like the context changing. Each tab's cards now have their own identity (`.id(tab.id)`), so a switch shows the new tab's value straight away, while growth within a tab still animates.

## [0.8.3] - 2026-10-21
- Fix: after `/compact` (or auto-compaction) the sidebar's context ring kept the pre-compaction size until Claude's next reply. It now reads the transcript's `compact_boundary` entry and shows the compacted size straight away. A subagent's compaction doesn't move it.

## [0.8.2] - 2026-10-20
- Fix: with several tabs attached to different tmux sessions, they all followed the same pane (whichever tmux client was used last), so one Claude working made every tmux tab animate, and they all saved that one session for Reattach. Each tab now finds its own client in `tmux list-clients` by its tty. `display-message -c <tty>` was the culprit: without `-t` it describes tmux's most recently active client, whatever tty is named. Tabs saved with the wrong session correct themselves on the next poll.

## [0.8.1] - 2026-10-17
- Closing a window no longer throws its tabs away. It's kept (the last 10 closed), and **Shell → Reopen Closed Window** (`⌘⇧T`) brings it back with its tabs, groups, names and saved Claude and tmux sessions. Before, closing the last window and then quitting saved an empty layout, so the next launch started from one fresh tab.
- Quitting with no window open brings back the last window you closed at the next launch.
- **Shell → Resume All Sessions**: every tab offering Resume, Reattach or Resume in tmux takes it at once, in every window. Handy after a restart with many Claude tabs.
- A save that drops a window first copies the file on disk to `layout.json.prev`, so a layout lost by mistake can be put back by hand.
- Debug command `resumeAll`.

## [0.8.0] - 2026-10-14
- New app icon: a dark terminal slab with a `>` prompt and an orange asterisk cursor, with three tab-group bars along its top. Drawn as SVG (`Resources/AppIcon.svg`) after a Nano Banana Pro concept (`scripts/gen-icon-art.py`), rendered by `scripts/render-icon.sh`.
- Claude Code inside tmux: when a tmux client is in front of a tab, Smart Terminal asks tmux which pane it shows (`display-message -c <tty>`, at most once a second, off the main thread) and follows the Claude in that pane. Tab name and status, notifications, the Dock badge and the sidebar's Claude pane all work. A client started with `-L`/`-S` asks that server.
- Claude started through a wrapper (`zsh -c 'claude …; exec bash -l'`, as tmux panes often run it) is found too. The wrapper leads the foreground group, so Claude is looked for among its children.
- Recovery for tmux tabs. The tab remembers the tmux session it was attached to, and after a restart offers **Reattach** if the server still has it (Claude inside never stopped) or **Resume in tmux** if it's gone: the session is recreated in Claude's folder, `claude --resume` is typed into it, and the tab attaches. Detaching yourself forgets the session.
- Saved Claude sessions remember Claude's folder (`--resume` only finds a session from its own project folder).
- A Claude that is still running but no longer in front (suspended, or in another tmux window) keeps its resume offer.
- Fix: the resume bar was see-through in translucent windows.
- Debug `state` lists each tab's saved Claude and tmux sessions and its recovery offer.

## [0.7.0] - 2026-09-25
- Sidebar panes: icons in the sidebar's header row switch between Clipboard and Claude Code, like Xcode's inspector tabs. The pane's title (and the clipboard's count and Clear) share that row. A copy arriving while another pane is showing puts a dot on the clipboard icon.
- Claude Code pane, following the current tab:
  - Live status: an animated asterisk and a turn timer while Claude works, "Needs you" with the reason when it waits, time since the last reply when idle.
  - Context meter: tokens in context and a ring against the context window. Replies log the model without its `[1m]` suffix, so the window comes from, in order: `/context` or `/model` output in the transcript; a context already past 200k; the folder's last-used model in `~/.claude.json`; else an assumed 200k, shown as "~200k". The tooltip names the source.
  - "Resumed" instead of "Started" for a session opened with `--resume` or `--continue`.
  - Session tokens: output, input, cache read, cache write.
  - Subagents, newest first: a spinning asterisk and live timer while running (with a "2 running" badge), then a check with duration, tokens and tool calls, or a red cross if it failed. Background subagents finish through their task notification, wherever it lands: a normal message, several in one message, or queued while Claude was mid-turn (a `queue-operation` enqueue, delivered later as a `queued_command` attachment). Duration, tokens and tool calls come from the notification's own stats. The default `general-purpose` type isn't shown. One launched before a `--resume` that never reported back shows as "didn't finish" instead of running forever. The list starts over when a new prompt launches subagents and all previous ones completed; a running or failed one keeps the list, so it isn't missed.
  - Hover a subagent for a 600×400 popover: its latest tool call ("Now · Bash(git status)"), then its activity as a mini terminal in Claude Code's style (its task, what it says, each tool call with the first lines of its result), following the newest line. Its transcript is found through the `.meta.json` Claude writes next to it, so running subagents work too, and only new lines are read, once a second, while the popover is open.
  - The model's name ("Opus 5.5") heads the context card.
  - Prompts typed, last turn duration, session start.
- Token totals count each API message once. A response is logged as one line per content block, each repeating the same usage, so counting lines would inflate totals about 2.3×.
- Each transcript is read once in full, off the main thread and one at a time (11 MB in 0.23 s), then followed as it grows.
- README screenshot is now taken from the app by `scripts/demo-screenshot.sh`, with invented data: a clean `HOME` (`demo/home`), a throwaway `CLAUDE_CONFIG_DIR`, and `demo/fake-claude.swift` standing in for `claude`. It shows tab groups (one collapsed), a Claude tab at work and the sidebar's Claude pane with subagents. The drawn mock (`scripts/mock-screenshot.py`) is gone.
- Fix: a new tab that starts in its folder and whose shell never sets a title was named "Terminal"; the first poll now always reports.
- The app honours `$HOME` for its default folder, and passes `CLAUDE_CONFIG_DIR` to its shells (it already read Claude's files from there).
- Debug commands `snapshotClaude`, `showSubagent`, `pane`, `subagentPopover`, `toggleGroup`, `typeSlow`, `activate`.

## [0.6.0] - 2026-09-25
- Sidebar (⌃⌘S, or the button at the right end of the tab strip): a resizable panel on the right, flush with the tab strip (drag its left edge; the width is remembered).
- Its first tool is a clipboard history. Every copy lands at the top and flashes: text (including `pbcopy`), images (screenshots, Copy Image, with size and format) and files copied in Finder (Quick Look previews). With the sidebar closed, its button bounces and shows a dot instead. Click an entry to copy it again (it confirms "Copied" in place); right-click to paste it into the current tab (files as quoted paths; images saved as a temporary PNG and pasted as its path, which Claude Code attaches) or delete it. Ages read "now", then "5 min ago", "3 hr ago", then the date; no seconds, which go stale the moment they're drawn. Holds the last 50 copies, in memory only. Copies marked concealed or transient (password managers) are skipped.
- Clicking an image file copied in Finder also puts the image itself on the clipboard (as PNG), so ⌃V in Claude Code pastes it; before, the clipboard held only the file reference and Claude reported no image.
- Fix: a 1 pt see-through line between the tab strip and the terminal in translucent windows (the divider was its own row with nothing painted behind it; it's now drawn on the strip).
- Every expanded group gets its own "+" in its color, right after its last tab: it opens a tab at the end of that group, in the folder of the group's last tab.
- The "+" at the end of the strip now always opens an ungrouped tab at the end. It used to join whichever group the selected tab was in, so the result depended on the selection. ⌘T still opens the tab next to the current one.
- Debug commands `sidebar`, `snapshotSidebar`, `restoreClip`, `pasteClip` and `newTabInGroup`.

## [0.5.1] - 2026-09-24
- CI: actions/checkout v5 (Node 20 deprecation).
- Fix: the activity dot never cleared on tmux tabs. tmux redraws its status-line clock every few seconds, which counted as output and re-marked the tab right after you left it. Activity now requires a line break in the output (idle tmux redraw: 133 B, no line break; a printed line: 31 B, one line break).
- A visible gap where a group ends, so ungrouped tabs right after a group no longer look like members of it.
- README modelled on wims: story, full usage, how it works, privacy, configuration, limitations; mocked screenshot.
- SECURITY.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md, .editorconfig, CI (build + tests on macOS 26).
- Planning docs moved to docs/.

## [0.5.0] - 2026-09-24
First public release: signed, notarized, universal (Apple silicon + Intel), macOS 26+.
- App icon, About panel (version, build, credits), MIT licence.
- Tab keeps Claude's live ◐/✳ status prefix when renamed.
- Hardened runtime + Apple Events entitlement; debug remote-control channel compiled out of release builds.

## [0.1.0] - development
- Import tabs from Terminal.app (Claude handover, tmux re-attach, grouped by folder).
- Resume Claude sessions after relaunch; "needs you" notifications and Dock badge; waiting status.
- Terminal.app-style window title: folder — live program title (animated) — process ◂ command — cols×rows.
- Claude Code-aware tabs: session name (/rename, AI title) as the tab title, working/waiting glyph, tooltip with last prompt and PR.
- Move a tab within its group with ⌃←/⌃→ (⌃⌥←/⌃⌥→ alias).
- Initial tab system: tabs, rename, named/colored groups, drag and drop, multi-window, layout persistence.
