# Smart Terminal

A native macOS terminal: Terminal.app, plus Chrome-style **tab groups**. Rename tabs,
gather them into named, colored, collapsible groups, and drag tabs and groups
around, between windows, or out into new ones.

## Install
Download **SmartTerminal-0.5.0.dmg** from [Releases](https://github.com/pluginslab/smart-terminal/releases), open it, and drag Smart Terminal to Applications. It is a signed and notarized universal build (Apple silicon + Intel). It needs **macOS 26 (Tahoe)** or later.

On first use macOS may ask for permission to:
- **show notifications**, used when a Claude session in another tab finishes or needs you;
- **control Terminal**, only when you use *Import Tabs from Terminal.app*.

## Highlights
- **Tab groups:** rename tabs, and gather them into named, colored, collapsible groups (Chrome's nine colors). Drag tabs and whole groups to reorder, between windows, or out into a new window.
- **Feels like Terminal.app:** it imports your Terminal.app default profile (font, colors, translucency), and the title bar shows the same live format: `folder — ◐ program title — process ◂ command — cols×rows`.
- **Claude Code aware:** tabs take the session's name (`/rename` or Claude's AI title) and show its live ◐/✳ status. A notification and Dock badge tell you when a Claude you can't see finishes or waits on a permission prompt. Sessions can be resumed after a restart.
- **Import from Terminal.app:** brings your open Terminal.app tabs over, grouped by project. Claude sessions are handed over, and tmux sessions are re-attached.
- **Layout persistence:** windows, groups, names and folders survive a restart.

## Build from source
```bash
scripts/bundle.sh --open     # debug build of SmartTerminal.app, then launch it
scripts/dev-run.sh           # isolated dev instance (own layout file, debug channel on)
scripts/test-run.sh          # throwaway test instance for automated checks
swift test                   # core model tests
scripts/release.sh           # universal build, Developer ID signing, notarization, DMG in dist/
```
Swift 6.2 / Xcode 26. Terminal emulation is by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). Project docs: `scope.md`, `plan.md`, `progress.md`.

## Using it
| Action | How |
|---|---|
| New tab (next to the current one, same group, same folder) | ⌘T, "+" |
| New tab at the end, ungrouped | double-click empty strip space |
| Rename tab | double-click the tab, ⌘⇧I (Enter commits, Esc cancels, empty = automatic name) |
| Group the current tab / edit its group | ⌥⌘G, or right-click the tab → Add Tab to New Group |
| Collapse / expand a group | click its chip, ⌥⌘C |
| Edit group name, color, actions | double-click the chip, or right-click the chip |
| Move tabs | drag: dropping between a group's tabs joins it; the left edge of a chip = before the group; onto a chip = into the group |
| Move a group | drag its chip |
| Tab or group to a new window | drag it out onto the desktop, or use the context menu |
| Move tab left/right within its group | ⌃← / ⌃→ (needs System Settings → Keyboard → Shortcuts → Mission Control → "Move left/right a space" off), or ⌃⌥← / ⌃⌥→ |
| Switch tabs | ⌘1…⌘8, ⌘9 (last), ⌃Tab / ⌃⇧Tab, ⌘⇧] / ⌘⇧[ |
| Font size | ⌘+ / ⌘- / ⌘0 |
| Clear, Find | ⌘K, ⌘F |

### Coming from Terminal.app
**Shell → Import Tabs from Terminal.app…** lists your Terminal.app tabs grouped by project folder. Claude sessions are handed over (`/exit` there, `--resume` here with the same flags), tmux sessions are re-attached here and detached there, and shells reopen in the same folder. Claude sessions that are working right now start unchecked.

### Claude Code tabs
When Claude Code runs in a tab (and you haven't renamed the tab), the tab takes the session's name: your `/rename`, else Claude's AI title, else "Claude · folder". The glyph shows its state: a spinning ✱ while working, and a filled orange ✱ when it finished while you were in another tab. An orange speech bubble means it is waiting on a permission prompt or question. You get a macOS notification (click to jump to the tab) and a Dock badge when a Claude you can't see finishes or needs you. After a restart, tabs that ran Claude offer **Resume**.

Layout is saved to `~/Library/Application Support/SmartTerminal/layout.json`. Shells restart in each tab's last folder.

## License
MIT. See [LICENSE](LICENSE).
