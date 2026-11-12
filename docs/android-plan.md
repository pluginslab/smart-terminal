# Smart Terminal for Android: Xiaomi Pad 8 Pro

Goal: parity with **iPad 0.2.0** (`ipad-v0.2.0`, `587230e`) on a Xiaomi Pad 8 Pro (HyperOS 3, Android 16,
11.2" 3.2K, USB-C). Same idea as the iPad: no local shell, every tab is a tmux session on
supermaschine over SSH, in the Mac's Mail-style columns.

## What the iPad session taught us (2026-11-12, session `4d2cefa0`)

The iPad went from "make a plan" to 0.2.0 in about three hours. What took the time, and what
it means here:

| iPad challenge | Root cause | Android answer, decided up front |
|---|---|---|
| Swipe selected text in tmux instead of scrolling | `mouse on` makes the emulator send drag = held button + motion | Vertical pan becomes wheel events (button 4/5) with momentum; long-press selects. Day-one feature, not a fix. |
| tmux drew wider than the screen, status bar wrapped | PTY requested before layout; resize sent before the channel existed | Send `window-change` with the real cols/rows right after the shell channel opens, and on every size change after. |
| Terminal went blank after rotating | Two containers both claimed the one terminal view during the rebuild | Android version of the same trap: activity recreation + "view already has a parent". Handle config changes in the activity (`configChanges=orientation\|screenSize\|smallestScreenSize\|screenLayout\|keyboard\|keyboardHidden\|density`), keep panes in a process-scoped holder, detach the view from its old parent before attaching. |
| Picking a session raised the keyboard | Focus followed selection | Only a tap on the terminal shows the IME. A hardware keyboard gets focus at once. |
| Taps above the home bar woke Siri | Key bar too close to the system gesture area | Pad the key bar by `WindowInsets.systemGestures` + `navigationBars`, more in portrait. Bottom gesture area can't be excluded on Android. |
| Portrait lists squeezed the terminal and reflowed tmux | Side-by-side columns | Lists slide **over** the terminal in portrait (overlay, not push). |
| Left-edge swipe for the lists | iPadOS convention | **Conflicts with Android's back gesture.** Use the header button + predictive back to close; exclude a short strip of the left edge (`systemGestureExclusionRects`, max 200dp) only if it feels right on the device. |
| `X` in the header killed a tmux session in one tap | Destructive action too close to the mic | No close in the header; long-press menu only, as now. |
| Stray `;37;73t` typed into zsh | Terminal replies to window-size queries leaking | Watch for it from the first build; test with `printf '\e[18t'`. |
| YubiKey "set up" but never recognised | Off-by-one in our own attestation parser | Use a library for CTAP, not a hand parser. Log every failure reason on screen from day one. |
| Citadel 0.12.1 swapped its SSH dep for a fork from an unrelated account | Supply chain | Exact versions, Gradle dependency verification (`verification-metadata.xml`), no JitPack for anything that runs SSH; vendor instead. |
| No screenshots over USB (iPadOS 26), `snap-request` hack | Platform | Not needed: `adb exec-out screencap -p`, `adb shell input tap/swipe`, `scrcpy`. Claude can see and drive the tablet itself, which closes the loop the iPad never had. |
| Signing/profile/Developer Mode round trips with Xcode | Apple provisioning | Own release keystore; `adb install -r`. HyperOS friction instead: USB debugging **and** "Install via USB" + "USB debugging (Security settings)", which need a Xiaomi account signed in. |
| iPadOS cuts the socket in the background | Platform | HyperOS kills even harder. Reconnect on resume (parity). Battery saver "No restrictions" + autostart for the app; foreground service is a later option, not 0.1. |

What made the iPad fast: the host does the work. One SSH round trip (`tmux list-panes`, `ps`,
`~/.claude/sessions/*.json`) gives every row its Claude state, title and git; dictation reads
Glossa's config from the host. Android reuses those scripts byte for byte.

## Stack

| Part | iPad | Android |
|---|---|---|
| Language/UI | Swift, SwiftUI `NavigationSplitView` | Kotlin, Jetpack Compose, Material 3 adaptive (`ListDetailPaneScaffold` / window size classes) |
| Terminal | SwiftTerm `TerminalView` | **Spike:** Termux `terminal-emulator` + `terminal-view` (Apache-2.0, vendored, fed by an SSH channel instead of a local PTY) vs ConnectBot `termlib` (Apache-2.0, Compose, libvterm). Pick by: mouse/wheel reporting, IME, selection, 3.2K rendering speed. |
| SSH | Citadel 0.12.0 | sshj (Apache-2.0), one connection: exec channels for status, a shell channel + PTY per tab |
| Device key | ed25519 in the keychain | P-256 in Android Keystore (StrongBox if present), non-exportable; signs through `Signature`. Stronger than the iPad's. |
| Host key | Pinned on first use | Same (sshj `HostKeyVerifier`) |
| Lock | Passkey API + AASA on pluginslab.com; Touch ID | **YubiKit Android** (FIDO2 over USB/NFC, no domain, no Google Play services needed) for the key; `BiometricPrompt` with `BIOMETRIC_STRONG or DEVICE_CREDENTIAL` (Xiaomi face unlock is usually Class 2, so the PIN/password fallback matters). Same 2-minute rule. |
| Dictation | AVAudioRecorder → Whisper | `AudioRecord` (16 kHz mono) → OkHttp multipart to the endpoint in `~/.config/glossa/config.json`; `network_security_config` allows cleartext for the tailnet/LAN only |
| Core model | `SmartTerminalCore` (Swift) | Kotlin port of the five types the iPad uses: `AgentStatus`, `ClaudeTitle`, `ClaudeSessionRecord`, `GitStatus`, `TabGroup`/`GroupColor` (~300 lines) |
| Font/theme | FiraCode Nerd Font Mono, Harbor colours | Same TTFs, same palette from `Theme.swift` |
| Network | Tailscale on the iPad | Tailscale Android app (MagicDNS resolves `supermaschine`) |

**Parity mechanism:** shared fixtures, not shared code. Captured real outputs (`tmux list-panes`,
`ps`, Claude session JSON, Claude titles, `git status --porcelain=v2`) go in `Tests/Fixtures/`;
the Swift Core tests and the Kotlin tests both read them and must agree. Swift-on-Android is not
worth the toolchain risk for 300 lines.

## Layout in the repo

```
android/                Gradle KTS project, app id com.pluginslab.smartterminal.pad
  app/src/main/...      Kotlin sources: lock/, remote/, dictation/, model/, ui/
  terminal/             vendored emulator module (if Termux wins the spike)
Tests/Fixtures/         shared by Swift and Kotlin tests
CHANGELOG.md            "## [Android 0.x.y]" entries, tags android-v0.x.y
```

## Milestones (each one installed on the Pad and checked by screenshot before moving on)

**0. Toolchain (½ h).** Link `openjdk@17` (installed, not on PATH; Android Studio's JBR is
fine too), `sdkmanager` for platform 36 + build-tools 36, Gradle wrapper, `scrcpy`. On the Pad:
Developer options, USB debugging, Install via USB, USB debugging (Security settings).
Confirm `adb devices` and a hello-world install.

**1. Terminal spike (2 h).** Both emulators, a hard-coded `ssh pluginslab@supermaschine` into
`tmux new -A -s android-test`. Criteria: Claude Code renders right, wheel scroll in tmux,
long-press select, IME + hardware keyboard (Esc, Ctrl, arrows), real size on attach, rotation
keeps content. Decide and delete the loser.

**Spike result (2026-11-12): Termux wins**, without building termlib (published the same day,
needs Compose 2026.09 / Kotlin 2.4, can't paste yet). On the Pad: sshj + Keystore-wrapped P-256
key, tmux attached at its real size, Harbor colours and FiraCode, IME works, rotation and window
resizes keep the screen, a swipe scrolls tmux (wheel events). Lessons:
- The SSH read loop needs its own thread. Sharing the single writer thread queued every keystroke,
  wheel event and resize behind it forever.
- A test that turns mouse reporting on inside a pane (`printf '\e[?1000h'`) makes tmux forward the
  wheel to the shell, which then shows `64;70;8M`. That's the likely source of the iPad's stray
  `;37;73t` too: a pane in a mouse/report mode, not the app.
- Termux sends one wheel step per line of finger travel; tmux scrolls 5 lines per step, so it is
  fast. Tune to the iPad's one step per 2.5 rows in 0.1.0.
- HyperOS opens new apps in a floating window; `am start --windowingMode 1` for full screen in tests.

**2. Android 0.1.0: the iPad 0.1.0 feature set.** Done 2026-11-12 (`android-v0.1.0`), checked on the Pad by screenshot in landscape and portrait; dictation and the group menus by hand.
- Device key, setup card with Copy Key (I add it to supermaschine's `authorized_keys` as
  `smart-terminal-android (Xiaomi Pad 8 Pro)`), pinned host key.
- Host poller (3 s status, git every third tick) with the iPad's scripts.
- Columns: groups / sessions / terminal in landscape; terminal full screen in portrait with the
  lists over it; groups collapse (button + Ctrl+Meta+S); remembered per orientation.
- Rows: Claude glyph + title, folder, git branch/changes, last activity, "open elsewhere".
- Groups, renames, membership kept on the device (DataStore); new session `android-N`;
  close from the long-press menu only.
- Terminal pane per session kept alive across switches; reconnect + reattach on resume.
- Key bar: keyboard, esc, ⇧tab, tab, ^C, one swipe arrow key with haptics, return, mic at the
  right edge; hides while the IME is up; clear of the gesture bar.
- Dictation with waveform; keys greyed while recording; return reappears after the text lands.
- Theme, font, Streamline icon (adaptive icon from `AppIcon-art.png`).

**3. Android 0.2.0: the lock.** YubiKey set up once (credential id + public key stored),
assertion over a fresh challenge verified on device; biometric/PIN fallback; nothing connects
until unlocked; relock after 2 minutes in the background. `FLAG_SECURE` on the window so the
recents thumbnail doesn't show terminal contents (the iPad doesn't do this yet; worth porting back).

**4. Tablet polish (Android-only).** Split-screen / floating window sizes (resizeable, no reflow storms), 144 Hz
smooth scrolling, stylus does nothing surprising.

## Testing loop

- `./gradlew installDebug` then `adb shell am start`; `adb exec-out screencap -p > snap.png`
  for every visual check; `adb shell input` for taps, swipes and rotation
  (`settings put system user_rotation`), so rotation and scroll fixes get verified by me, not
  only by you.
- Debug flags as on the iPad: `--ez nolock true`, `--es dictate <session>` via intent extras.
- `./gradlew test` runs the Kotlin side of the shared fixtures; `swift test` keeps the Mac/iPad side.

## Distribution

Sideload over `adb` for now (the TestFlight-equivalent decision, made the same way as the iPad's:
test the look first). Signed with a release keystore stored in `~/servers/CREDENTIALS.md`.
Play internal testing later if it sticks.

## Decided (2026-11-12)

1. Global ROM, Google Play services present. YubiKit stays the choice anyway (no domain, works offline).
2. No hardware keyboard: the key bar and the IME are the primary input. The key bar ships in the
   first usable build, not as polish, and the IME path (Gboard over the terminal, autocorrect off,
   Enter/Backspace/arrows) is a criterion of the terminal spike.
3. supermaschine only, as on the iPad. No host picker.
