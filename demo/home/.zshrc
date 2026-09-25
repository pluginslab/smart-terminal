# Demo shell for the README recording: a plain prompt, no personal config.
HISTFILE=/dev/null
PROMPT='%F{81}%1~%f %F{245}❯%f '
unset RPROMPT
unsetopt PROMPT_SP   # no "%" marker for partial lines

# `claude` is the demo's fake (demo/fake-claude.swift, built by scripts/record-demo.sh).
# A function, not PATH, so the real Claude Code can never start here; if the fake
# isn't built, this fails instead of falling through.
claude() {
    local fake="${HOME:A:h:h}/.build/demo-bin/claude"
    [[ -x "$fake" ]] || { print -u2 "demo: fake claude not built (run scripts/record-demo.sh)"; return 1; }
    "$fake" "$@"
}
