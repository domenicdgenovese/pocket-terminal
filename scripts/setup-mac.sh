#!/bin/bash
# setup-mac.sh — Mac side of the pocket terminal. Idempotent; safe to re-run.
#
# Deliberately requires NO admin password: it runs a per-user sshd on a high
# port instead of enabling system Remote Login on 22. The one thing it cannot
# do is install/sign in to Tailscale — that needs a human (see the end).
#
#   ./setup-mac.sh [PORT]      # PORT defaults to 2222

set -euo pipefail

PORT="${1:-2222}"
# Resolve where this script lives so bundled helpers (pocket-doctor) are found
# regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POCKET="$HOME/.pocket"
SSHD_DIR="$POCKET/sshd"
AGENT="$HOME/Library/LaunchAgents/com.pocket.sshd.plist"
PROJECT_DEFAULT="${POCKET_PROJECT:-$HOME}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()  { printf '    ✓ %s\n' "$1"; }

# ---------------------------------------------------------------- dependencies
say "Dependencies"
if ! command -v brew >/dev/null 2>&1; then
  echo "    ! Homebrew not found. Install from https://brew.sh first." >&2
  exit 1
fi
# Homebrew lives in /usr/local on Intel and /opt/homebrew on Apple Silicon.
# Ask rather than assume — hardcoding either one breaks half of all Macs.
BREW_BIN="$(brew --prefix)/bin"
ok "homebrew prefix: $BREW_BIN"

for pkg in mosh tmux; do
  if command -v "$pkg" >/dev/null 2>&1; then ok "$pkg present"
  else brew install "$pkg" >/dev/null && ok "$pkg installed"; fi
done

# sshd gives child sessions a minimal PATH, so mosh-server/tmux must be spelled
# out. Include both Homebrew locations: harmless if one doesn't exist, and it
# keeps the config portable if this machine is ever migrated to the other arch.
REMOTE_PATH="$HOME/.local/bin:$BREW_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ------------------------------------------------------------------- host keys
say "SSH host key"
mkdir -p "$SSHD_DIR"; chmod 700 "$POCKET" "$SSHD_DIR"
if [ -f "$SSHD_DIR/host_ed25519_key" ]; then
  ok "host key exists (keeping it — regenerating would break saved devices)"
else
  ssh-keygen -t ed25519 -f "$SSHD_DIR/host_ed25519_key" -N '' -C 'pocket-sshd' -q
  ok "host key generated"
fi

mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
ok "authorized_keys ready"

# ------------------------------------------------------------------ sshd config
say "sshd config (port $PORT)"
cat > "$SSHD_DIR/sshd_config" <<EOF
# Pocket terminal — user-level sshd. No admin rights needed.
# Keys only; reachable in practice only over Tailscale.

Port $PORT
HostKey $SSHD_DIR/host_ed25519_key
AuthorizedKeysFile $HOME/.ssh/authorized_keys

PubkeyAuthentication yes
# A non-root sshd cannot do PAM, so password auth is impossible regardless.
# This makes that explicit — and it is why ssh-copy-id can never work here.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers $USER

PidFile $SSHD_DIR/sshd.pid
LogLevel INFO
StrictModes yes
UsePAM no

# Non-login shells get a minimal PATH; mosh-server must still be findable.
# LANG matters because mosh-server refuses to start without a UTF-8 locale and
# mobile clients (Blink included) frequently send none.
# CAREFUL: sshd honours only the FIRST SetEnv line — later ones are ignored
# outright. Splitting these across lines silently drops everything after PATH,
# which reintroduces the UTF-8 failure with no hint as to why.
SetEnv PATH=$REMOTE_PATH LANG=en_US.UTF-8 LC_CTYPE=en_US.UTF-8

AcceptEnv LANG LC_*
EOF
/usr/sbin/sshd -f "$SSHD_DIR/sshd_config" -t && ok "config validates"

# ------------------------------------------------------------------ launchagent
say "LaunchAgent (keeps sshd running across logins)"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.pocket.sshd</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/sbin/sshd</string>
        <string>-e</string>
        <string>-D</string>
        <string>-f</string>
        <string>$SSHD_DIR/sshd_config</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$SSHD_DIR/sshd.log</string>
    <key>StandardErrorPath</key><string>$SSHD_DIR/sshd.log</string>
</dict>
</plist>
EOF
launchctl unload "$AGENT" 2>/dev/null || true
launchctl load "$AGENT"
sleep 2
launchctl list | grep -q com.pocket.sshd && ok "sshd running on port $PORT"

# ---------------------------------------------------------------- pocket helper
say "pocket helper"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/pocket" <<EOF
#!/bin/zsh
# pocket — attach (or create) the persistent "pocket" tmux session, so a
# dropped phone connection leaves the work running on the Mac.

export PATH="\$HOME/.local/bin:$BREW_BIN:/usr/local/bin:/opt/homebrew/bin:\$PATH"
export LANG="\${LANG:-en_US.UTF-8}"
export LC_CTYPE="\${LC_CTYPE:-en_US.UTF-8}"
export TERM="\${TERM:-xterm-256color}"

PROJECT="\${1:-$PROJECT_DEFAULT}"
[ -d "\$PROJECT" ] || PROJECT="\$HOME"

# Already running? Attach quietly rather than reprinting over existing work.
if tmux has-session -t pocket 2>/dev/null; then
  exec tmux attach -t pocket
fi

tmux new-session -d -s pocket -c "\$PROJECT"

# The status bar earns its space. The most common confusion in this setup is
# losing track of which machine the prompt belongs to — running \`mosh mac\`
# while already connected yields a cryptic DNS error. A permanent on-screen
# "MAC" marker removes that whole class of mistake.
tmux set-option -t pocket status-style "bg=colour24,fg=colour255" 2>/dev/null
tmux set-option -t pocket status-left  " #[bold]MAC#[default] " 2>/dev/null
tmux set-option -t pocket status-left-length 12 2>/dev/null
tmux set-option -t pocket status-right " #(pmset -g batt | grep -o '[0-9]*%%' | head -1) #[bold]#S " 2>/dev/null
tmux set-option -t pocket status-interval 30 2>/dev/null

tmux send-keys -t pocket 'clear; pocket-doctor --brief' Enter

exec tmux attach -t pocket
EOF
chmod +x "$HOME/.local/bin/pocket"; ok "~/.local/bin/pocket"

# On-device diagnostics. When this breaks the user is holding a phone, possibly
# far from home — one opaque error is useless there. `doctor` reports each layer
# separately so the answer is "Tailscale is down", not "connection failed".
if [ -f "$SCRIPT_DIR/pocket-doctor" ]; then
  cp "$SCRIPT_DIR/pocket-doctor" "$HOME/.local/bin/pocket-doctor"
  chmod +x "$HOME/.local/bin/pocket-doctor"
  ln -sf "$HOME/.local/bin/pocket-doctor" "$HOME/.local/bin/doctor"
  ok "~/.local/bin/doctor"
else
  echo "    ! pocket-doctor not found next to this script; skipping"
fi

# `cheat` and `fix`. Typing is expensive on a phone and half-remembered syntax
# is worse than none, so the reference lives in the terminal rather than in a
# document the user would have to go find on another device.
for helper in cheat fix; do
  if [ -f "$SCRIPT_DIR/$helper" ]; then
    cp "$SCRIPT_DIR/$helper" "$HOME/.local/bin/$helper"
    chmod +x "$HOME/.local/bin/$helper"
    ok "~/.local/bin/$helper"
  else
    echo "    ! $helper not found next to this script; skipping"
  fi
done

# ------------------------------------------------------------------------ tmux
say "tmux (touch-friendly)"

# Mouse mode must be OFF for phone use. A swipe registers as scroll-up, which
# drops tmux into copy mode — and there every keystroke becomes navigation, so
# the keyboard silently stops working. Users read that as a frozen connection
# and go hunting through Tailscale and sshd, where nothing is wrong. Losing
# swipe-scroll costs far less than losing the ability to type.
if [ -f "$HOME/.tmux.conf" ] && grep -q "set -g mouse" "$HOME/.tmux.conf" 2>/dev/null; then
  ok "~/.tmux.conf already sets a mouse mode — leaving it alone"
else
  cat >> "$HOME/.tmux.conf" <<'TMUXEOF'

# --- pocket terminal ---------------------------------------------------------
# Off on purpose: on a touchscreen, scrolling traps you in copy mode and the
# keyboard appears to die. Scrollback is still available via `ctrl-b [` (q exits).
set -g mouse off
set -sg escape-time 10
set -g history-limit 20000
TMUXEOF
  ok "wrote tmux settings to ~/.tmux.conf"
fi
tmux source-file "$HOME/.tmux.conf" 2>/dev/null || true

# ---------------------------------------------------------------------- locale
say "Shell environment"
if ! grep -q "en_US.UTF-8" "$HOME/.zshenv" 2>/dev/null; then
  cat >> "$HOME/.zshenv" <<'EOF'

# mosh-server requires a UTF-8 locale; mobile SSH clients often send none.
export LANG="${LANG:-en_US.UTF-8}"
export LC_CTYPE="${LC_CTYPE:-en_US.UTF-8}"
EOF
  ok "locale forced in ~/.zshenv"
else ok "locale already set"; fi

# Auto-attach tmux for remote sessions, so the phone side is a single command.
# Guarded: interactive + remote + not already in tmux + tmux exists.
# Escape hatch: connect with POCKET_NOTMUX=1 for a plain shell.
if ! grep -q "POCKET_AUTOSTART" "$HOME/.zshrc" 2>/dev/null; then
  cat >> "$HOME/.zshrc" <<'EOF'

# POCKET_AUTOSTART — phone connections land straight in the persistent session.
if [[ -o interactive ]] && [[ -n "$SSH_CONNECTION" ]] && [[ -z "$TMUX" ]] \
   && [[ -z "$POCKET_NOTMUX" ]] && command -v tmux >/dev/null 2>&1; then
  exec ~/.local/bin/pocket
fi
EOF
  ok "auto-attach added to ~/.zshrc"
else ok "auto-attach already present"; fi

# ------------------------------------------------------------------ stay awake
say "Power"
if pmset -g custom 2>/dev/null | sed -n '/AC Power/,$p' | grep -qE '^\s*sleep\s+0'; then
  ok "Mac will not idle-sleep on AC"
else
  echo "    ! pmset says the Mac may idle-sleep on AC."
  echo "      Changing that needs an admin password, so run it yourself:"
  echo "         sudo pmset -c sleep 0 womp 1"
  echo "      Add 'disablesleep 1' too if you run it lid-closed."
fi

# Belt and braces, and this part needs no admin rights at all. `caffeinate -s`
# asserts "do not sleep" only while on AC, so it cannot flatten the battery when
# unplugged. A sleeping Mac is the single most common way this setup dies: the
# phone just reports a timeout, which looks like a network fault and isn't.
cat > "$HOME/Library/LaunchAgents/com.pocket.keepawake.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.pocket.keepawake</string>
    <key>ProgramArguments</key>
    <array><string>/usr/bin/caffeinate</string><string>-s</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
launchctl unload "$HOME/Library/LaunchAgents/com.pocket.keepawake.plist" 2>/dev/null
launchctl load "$HOME/Library/LaunchAgents/com.pocket.keepawake.plist" 2>/dev/null
sleep 1
if pgrep -f "caffeinate -s" >/dev/null 2>&1; then ok "keep-awake agent running (AC only)"
else echo "    ! keep-awake agent did not start"; fi

# --------------------------------------------------------------------- summary
say "Next: Tailscale (needs a human)"
if [ -d /Applications/Tailscale.app ]; then
  ok "Tailscale.app installed"
  STATUS=$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status 2>&1 | head -1)
  echo "    status: $STATUS"
else
  echo "    Install it (the system app, NOT userspace mode — mosh needs real UDP):"
  echo "       brew install --cask tailscale-app"
fi
echo
echo "    Then sign in, and confirm the Mac's tailnet IP with:"
echo "       /Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4"
echo
say "Done — verify with scripts/verify-pocket.sh"
