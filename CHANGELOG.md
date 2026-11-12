# Changelog

## [Android 0.2.0] - 2026-11-12
- Android: a lock before anything starts, at launch and after more than two minutes away; nothing connects to the host until it is open. Unlock with a YubiKey over USB-C, set up once by touching it, or with the fingerprint, face or PIN (Android's own prompt). Unlike the iPad, the key is spoken to directly with FIDO2 through Yubico's SDK (yubikit 3.1.0; 3.2 needs compile SDK 37): its credential id and public key are kept on the tablet and each unlock checks the key's signature over a fresh challenge, on the device. No web domain or passkey service is involved. A key with a FIDO2 PIN isn't supported yet. A lock button sits in the terminal header. Debug builds: `--ez nolock true` skips it.
- Android: release builds keep the terminal out of the recents thumbnail (`FLAG_SECURE`), aren't debuggable, and are signed with the project's own key; the debug build is "Smart Terminal Dev" beside it.
- Android: fixed the microphone permission prompt on a fresh install (biometric 1.1.0 had pulled in a Fragment too old for it; Fragment 1.8.6 now).

## [Android 0.1.0] - 2026-11-12
The first Android version, for the Xiaomi Pad 8 Pro (HyperOS 3, Android 16), installed over adb (not on Play). The iPad 0.1.0 feature set; the Mac and iPad apps are unchanged. Plan and lessons in `docs/android-plan.md`.
- New, Android (`android/`, a Gradle project): Smart Terminal for Android tablets, the Mail-style columns (groups, sessions, terminal) with each tab a tmux session on supermaschine over SSH. Landscape shows the columns; portrait gives the terminal the whole screen and lays the lists over it from the header button (not a left-edge swipe: that is Android's back gesture), back or picking a session puts them away. The groups column collapses from the sessions header.
- Rows as on the iPad: Claude's state and title, the folder's git state, last activity, "also open elsewhere". Groups, names and membership are kept on the tablet. New sessions are `android-N`; closing (it kills the tmux session) is in the row's long-press menu only.
- The terminal is Termux's emulator and view (Apache-2.0, vendored in `android/terminal/`, fed by an SSH channel). A swipe scrolls tmux (wheel events, at the iPad's speed), long-press selects, only a tap on the terminal raises the keyboard. Each tab's terminal lives as long as the app, so rotation and resizing HyperOS's floating window keep the screen; tmux gets the real size on attach and on every change.
- SSH is sshj. The tablet makes its own ecdsa-sha2-nistp256 key, kept encrypted under an Android Keystore key, and pins the host's key on first connect. `supermaschine` needs Tailscale; at home it falls back to the LAN address.
- Key bar: keyboard, esc, ⇧tab, tab, ^C, one swipe arrow key with haptics, return, and the microphone at the right edge, clear of the gesture bar. Hidden while the on-screen keyboard is up. Dictation as on the iPad, through the host's Glossa config; the keys grey out and a waveform shows while recording, scaled to the recording's own loudest level (Android's voice input comes in much quieter than the iPad's).
- The Streamline icon, as an adaptive icon.

## [0.17.0] - 2026-11-12
- New: a lock. At launch, and whenever the screen locks or the Mac sleeps, every window shows the lock instead of its terminals until you unlock; shells, tmux and Claude keep running behind it, but nothing of them shows, keys meant for a terminal are dropped, the menus are off and the window title says Locked. Lock by hand with ⇧⌘L, Smart Terminal ▸ Lock Smart Terminal, or the lock button next to the sidebar button.
- Unlock with a YubiKey you already use for SSH: any `~/.ssh/id_*_sk*` key. `ssh-keygen -Y sign` signs a fresh random challenge on the key and `ssh-keygen -Y verify` checks it against the key's `.pub` (Homebrew's OpenSSH, which talks to FIDO keys). Keys made without a touch are tried first, so one left plugged in (a Nano) unlocks at once; one that needs a touch is asked for next. Or Touch ID, with the login password as fallback.
- Only the installed app locks; dev and test builds don't, unless `SMART_TERMINAL_LOCK=1` (`SMART_TERMINAL_LOCK_NOKEY=1` hides the keys, for tests). With no key file and no Touch ID or password policy it doesn't lock at all, so it can't shut you out.
- `scripts/test-run.sh` launches the test instance in the background, so it never takes the keyboard from what you are typing in.

## [iPad 0.2.1] - 2026-11-12
- iPad: a lock button at the right of the terminal header (⇧⌘L on a keyboard), to lock before walking away.

## [iPad 0.2.0] - 2026-11-12
- iPad: a lock before anything starts, at launch and after more than two minutes away; nothing connects to the host until it is open. Unlock with a YubiKey (or another FIDO key) over USB-C, set up once on the device, or with Touch ID and the passcode. The key goes through Apple's passkey API: its public key is kept on the iPad and each unlock checks the key's signature over a fresh challenge, on the device. The API needs a web domain tied to the app, so pluginslab.com serves `/.well-known/apple-app-site-association` naming it (`webcredentials`), and the app has the associated-domains entitlement. No lock in the simulator or on an iPhone for now. Debug builds: `-nolock YES` skips it.
- iPad: the Streamline icon, the same as the Mac's.
- iPad: no deprecated UIKit calls left (the keyboard watcher reads the screen from the notification; the key prompt's fallback window takes the scene).

## [0.16.1] - 2026-11-12
- New app icon, in the line of Pluginslab's Agent and Intelligence apps: a window with its sidebar and a sparkle, turquoise on a dark tile. The iPad app uses it too. (The Streamline glyphs it is made from stay out of this public repo; `scripts/make-brand-icon.py` rebuilds it from them.)
- First public build since 0.15.6, so it also carries 0.16.0's removal of the browser pane.

## [iPad 0.1.0] - 2026-11-12
The first iPad version, run from Xcode onto a device (not on TestFlight yet). The Mac app is unchanged.
- iPad, portrait: the terminal takes the whole screen, as Mail does with a message. The lists slide in over it (swipe from the left edge, or the button in the terminal header) and go away when you pick a session; over it, not beside it, so tmux doesn't reflow. Landscape keeps the columns and remembers whether groups were shown. The key bar sits higher in portrait, clear of the home indicator (taps right above it reached the system, and repeated ones woke Siri).
- iPad: the terminal no longer goes blank after rotating. The rebuilt column and the old one both claimed the terminal view for a moment; now only the one on screen takes it.
- New, iPad (`iPad/`, an XcodeGen project; not shipped yet): Smart Terminal Pad, the Mac's Mail-style columns (groups, sessions, terminal) on an iPad, with each tab a tmux session on a host over SSH (supermaschine for now). The iPad makes its own ed25519 key and pins the host's key on first connect. Rows show Claude's state and title, the folder's git state and the last activity; groups and names are kept on the device. SSH is Citadel, pinned to 0.12.0 (0.12.1 swapped its SSH dependency for a fork from an unrelated account). `Package.swift` declares iOS and exports `SmartTerminalCore` for it.
- iPad: a swipe scrolls tmux (wheel events, with momentum) instead of drag-selecting in it; long-press still selects. The PTY gets the view's real size once attached, so tmux no longer draws wider than the screen.
- iPad: a key bar under the terminal for use without a keyboard: keyboard toggle, esc, ⇧tab, tab, ^C, one arrow key you swipe in a direction, return, and the microphone (larger, at the right edge). While dictating the keys grey out, return steps aside and a waveform of the mic level fills the space. The bar hides while the on-screen keyboard is up. Picking a session no longer raises the keyboard (a tap on the terminal does, or a hardware keyboard gets focus at once). No close button in the header any more: closing kills the tmux session, so it's in the row's context menu only. A sidebar button (⌃⌘S) collapses the groups column.
- iPad, debug builds: drop `snap-request` into the app's Documents and it writes `snap.png`, a screenshot of itself (iPadOS 26 has no USB screenshot service).
- New, iPad: dictation into the session in front. A microphone (⌘⇧D too): tap to record, tap again to stop; the audio goes to the Whisper server in the host's Glossa config (`~/.config/glossa/config.json` on the host, read over the SSH connection, with `glossary.txt` as vocabulary and the cursor's line as context) and the text is typed into the tmux pane. No settings on the device; the Mac's Glossa and the iPad share one server, one key and one glossary. Microphone permission is asked on first use; plain-HTTP endpoints on the tailnet are allowed (ATS exception).
- iPad, debug builds: `-dictate <s> -dictateSeconds <n>` records on a timer after launch, for tests where the simulator cannot be tapped.

## [0.16.0] - 2026-11-11
- Removed: the browser pane. Both engines (WebKit and the bundled Chromium), the globe button and `⇧⌘B`, View ▸ Browser Engine, the `open <url>` shell function, and the DevTools gate agent tools (devtools-fleet) drove the pane through. It didn't work well enough to keep. Web links you ⌘-click, and `open https://…` in a tab, go to your default browser again; devtools-fleet 0.4.0 always launches Chrome. The app is over 300 MB smaller without Chromium and its five helper apps.
- The local gate stays for `smart-terminal-mcp`'s proposed commands and keeps its file name (`chromium-gate.json`), so shells in tmux sessions that outlive the app still find it. Only `/v1/commands` is left on it.
- The Chromium profile the pane kept in Application Support (logins, cache) is deleted at launch. The app no longer declares itself a web browser to macOS, and drops the JIT entitlement Chromium needed.

## [0.15.6] - 2026-11-10
- Fixed: the app could lay its windows out over and over (two minutes at two-thirds of a core on 0.15.4) until AppKit threw and it quit. Whether the groups column is collapsed was read from layout and set as state inside that same layout pass, and the room it then made for the traffic lights could move the column and flip the answer back. The column now has to clearly cross over, and the change waits for the next run-loop turn.
- Fixed: a working Claude's title frames, several a second per tab, each wrote to state every window watches (since 0.15.3), redrawing them all for nothing.

## [0.15.5] - 2026-11-10
- The rest of the panels take the dark terminal's colours too: the clipboard sidebar, the browser pane's address bar, an empty browser waiting for an address (it showed a white page), and the Resume and proposal bars.

## [0.15.4] - 2026-11-10
- New: with a dark terminal, the panels take its colours ("Harbor"). The groups column, session list, title bar and status bar are a step lighter than the terminal's own background, in its hue, with dividers to match, and the selected session is Claude's amber with dark text. They follow your Terminal.app profile: another dark background brings matching panels, and a light one keeps the system's colours.

## [0.15.3] - 2026-11-10
- Fixed: tabs in tmux stopped coming back after a restart, and a session's git line stopped updating, after the app had run for a while. The tmux probe and git ran through Foundation's `Process`, whose `waitUntilExit` waits on a run loop; on Swift's task threads it could wait forever for a command that had long finished. Each stuck probe kept its tab from asking tmux again, so the tab never learned its session and had nothing to reattach; after a day 18 threads were parked like that. Helper commands now run with `posix_spawn` and `waitpid` on a queue of their own, with a timeout.
- Changed: a tab in ssh to tmux on another host (`cc-super`) keeps its session when the connection drops, and offers Reconnect at once. Before, any end of ssh, a drop included, made the tab forget it. Dismiss on the bar forgets it now.
- Fixed: after a Resume or Reconnect, a tab didn't offer again if what it started ended later the same day.

## [0.15.2] - 2026-11-10
- Removed: the Claude session index written for Mobile Agent (dropped 2026-11-10). Smart Terminal no longer writes `claude-sessions.json` and deletes the one left in its Application Support folder at launch. Per-tab Claude sessions for Resume, `SMART_TERMINAL_TAB` and everything else in the app are unchanged.

## [0.15.1] - 2026-11-09
- Fixed: an agent in tmux took over the browser pane of whichever tab you were looking at. A tool inside tmux can't trust `SMART_TERMINAL_TAB` (tmux hands every session the environment of the tab that started its server), so it asked for "the tab you're in". devtools-fleet 0.3.1 now reads the tab from the tmux session's own environment, where `cc-tmux` and Smart Terminal's tmux restore put it, and otherwise sends the tmux session it runs in; Smart Terminal gives it the tab showing that session (or that last showed it), and only then the tab in front.

## [0.15.0] - 2026-11-08
- New: tabs in ssh to tmux on another host come back after a restart, as `cc-super` runs it (`ssh supermaschine -t "tmux new-session -A -s name …"`). While such a client is in front, the tab remembers its ssh command; after a quit or crash it runs it again (on opening, or from its Reconnect bar), which reattaches to the session over there, Claude still running in it. Only ssh that attaches to tmux (`attach`, `a`, `new-session -A`) is remembered; a plain `ssh host` or a one-off remote command never runs again by itself. Ending ssh yourself forgets it.
- New: a "tmux" pill at the top right of each session in the sidebar when it runs in tmux; "tmux · host" for tmux over ssh. Its tooltip names the session.
- Fixed: a local tmux session recreated after a reboot now gets the tab's `SMART_TERMINAL_TAB` (as `cc-tmux` sets it). Before, tmux handed it the environment of whichever tab started its server, and Claude inside was counted as that tab's, in the sidebar and in `claude-sessions.json`.
- `claude-sessions.json` gives each tab and group its place: `order` on a tab is its position in its window's tab list, on a group its position in the sidebar (0 first). The file's dictionaries carry no order, so the Mobile Agent app can now list groups as the sidebar does. Additive; `version` stays 1.
- Faster: an agent driving a browser pane no longer pins Smart Terminal's CPU. Every DevTools message used to be handled on the main thread, and big ones (full-page screenshots, page snapshots, megabytes each) were re-scanned from the start each time 64 KB more arrived, then parsed three times. A full-page screenshot of a long page took over two minutes and timed out; the same 15 screenshots and 15 snapshots now take 20 seconds at about 28% CPU. Messages are now split and parsed once, on a queue of their own, and the terminals stay smooth meanwhile.
- Fixed: an agent's cookie calls in a browser pane failed after it closed the page they went through ("No page to read cookies through", or "Session with given id not found"). devtools-fleet closes that page when it restarts a browser, so a second restart, or moving a browser from Chrome into the pane and back, failed. The gate now drops its cookie session with the page and attaches to another of the agent's pages.

## [0.14.0] - 2026-11-07
- New: Claude can ask you to run a command instead of telling you to type `! …`. A tab opens beside the session, in its group, with the command typed at the prompt and a bar saying which session asked and why; press Return to run it (or edit it first). Claude then gets the exit status, the command as it ran and what it printed, and goes on. For logins, 2FA and password prompts, `sudo`, `npm publish`. Nothing runs without your Return: only one line of plain text is typed.
- `smart-terminal-mcp`, in the app bundle: the MCP server behind it. Add it once with `claude mcp add -s user smart-terminal -- /Applications/SmartTerminal.app/Contents/MacOS/smart-terminal-mcp`. Its tools are `propose_command` and `command_status`; outside Smart Terminal it offers none.

## [0.13.0] - 2026-11-06
- New: Back and Forward through the tabs you looked at, as in Slack: the arrows left of the title above the terminal, Tab ▸ Back / Forward, ⌃⌘← and ⌃⌘→ (Xcode's; ⌘[ and ⌘] stay the browser pane's). Each window keeps its own history of the last 100 tabs, however you got to them (a click, ⌘1, a notification, a group); tabs closed or moved to another window are skipped.
- New: Desktop / Mobile in Chromium panes. The button beside the address shows the layout (a computer or a phone) and switches it. Mobile is an iPhone: 390 CSS px wide (narrower if the pane is), the mobile viewport, touch, and Safari on iPhone's user agent; the page reloads so the site sees the phone from its first request. Desktop is as before: an agent's pages laid out 1366 px wide, zoomed to fit.
- Agents can switch too, with the tool they already have: chrome-devtools-mcp's `emulate` with a viewport (`390x844x3,mobile,touch`) lays the page out as that phone and the pane shows it; `emulate` without one goes back. Before, the pane's desktop zoom stayed on under the agent's phone metrics, the two compounded and the agent's clicks missed. The gate tells the app when an agent sets or clears a page's device metrics, and the app takes its zoom off meanwhile. When the agent goes, the pane goes back to what you chose.

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
