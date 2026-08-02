#!/bin/bash
# verify-pocket.sh — check each layer of the pocket terminal independently.
#
# The point of testing layers separately is that it turns one opaque failure on
# a phone screen into a specific answer: network vs auth vs mosh vs session.

PORT="${1:-2222}"
POCKET="$HOME/.pocket"
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
FAIL=0

hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }

hdr "1. sshd (auth layer)"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  pass "listening on port $PORT"
else
  bad "nothing listening on $PORT — run setup-mac.sh"
fi
launchctl list 2>/dev/null | grep -q com.pocket.sshd \
  && pass "LaunchAgent loaded (survives logout)" \
  || warn "LaunchAgent not loaded — sshd won't come back after a reboot"

if [ -f "$POCKET/sshd/host_ed25519_key.pub" ]; then
  FP=$(ssh-keygen -lf "$POCKET/sshd/host_ed25519_key.pub" 2>/dev/null | awk '{print $2}')
  pass "host key fingerprint: $FP"
  echo "      (compare against what the phone shows on first connect)"
else
  bad "no host key"
fi

hdr "2. Authorized device keys"
if [ -s "$HOME/.ssh/authorized_keys" ]; then
  ssh-keygen -lf "$HOME/.ssh/authorized_keys" 2>/dev/null | while read -r line; do
    pass "$line"
  done
else
  bad "authorized_keys is empty — no device can log in yet"
fi
echo "      Note: ssh-copy-id cannot work here (non-root sshd, no password auth)."

hdr "3. Tailscale (network layer)"
if [ ! -x "$TS" ]; then
  bad "Tailscale.app not installed — brew install --cask tailscale-app"
else
  SELF=$($TS status 2>&1 | head -1)
  case "$SELF" in
    *Logged\ out*) bad "logged out — sign in via the menu bar" ;;
    100.*)         pass "this Mac: $SELF" ;;
    *)             warn "unexpected status: $SELF" ;;
  esac
  IP=$($TS ip -4 2>/dev/null | head -1)
  [ -n "$IP" ] && pass "tailnet IP: $IP"

  # A stale userspace daemon leaves a ghost node and renames the real one.
  if pgrep -f "tailscaled --tun=userspace" >/dev/null 2>&1; then
    bad "a userspace tailscaled is ALSO running — duplicate node; remove its LaunchAgent"
  fi

  echo "  peers:"
  $TS status 2>/dev/null | tail -n +2 | while read -r line; do
    case "$line" in *offline*) printf '    · %s\n' "$line" ;;
                    *)         printf '    \033[32m·\033[0m %s\n' "$line" ;; esac
  done
fi

hdr "4. mosh (the anti-lag layer)"
command -v mosh-server >/dev/null 2>&1 \
  && pass "mosh-server: $(command -v mosh-server)" \
  || bad "mosh-server missing — brew install mosh"

grep -q "en_US.UTF-8" "$HOME/.zshenv" 2>/dev/null \
  && pass "UTF-8 locale forced in ~/.zshenv" \
  || bad "no locale in ~/.zshenv — mosh-server will refuse to start"

# sshd honours only the FIRST SetEnv line, so LANG must sit on the same line as
# PATH. Grep for the value, not the keyword — a second "SetEnv LANG=..." line
# would match a keyword grep while being completely ignored by sshd.
if head -1 <(grep "^SetEnv" "$POCKET/sshd/sshd_config" 2>/dev/null) | grep -q "LANG=.*UTF-8"; then
  pass "UTF-8 locale on the effective (first) SetEnv line"
else
  bad "LANG missing from the first SetEnv line — mosh will fail on UTF-8"
fi

hdr "5. Session persistence"
command -v tmux >/dev/null 2>&1 && pass "tmux: $(tmux -V)" || bad "tmux missing"
[ -x "$HOME/.local/bin/pocket" ] && pass "pocket helper present" || bad "pocket helper missing"
grep -q "POCKET_AUTOSTART" "$HOME/.zshrc" 2>/dev/null \
  && pass "auto-attach on remote login" \
  || warn "no auto-attach — user must type 'pocket' manually"

hdr "6. Live right now"
tmux ls 2>/dev/null | sed 's/^/  · /' || echo "  (no tmux sessions)"
N=$(pgrep -f mosh-server 2>/dev/null | wc -l | tr -d ' ')
echo "  mosh-server processes: $N"

hdr "Result"
if [ "$FAIL" -eq 0 ]; then
  echo "  All layers healthy."
else
  echo "  Something above is broken — see references/troubleshooting.md"
fi
echo
echo "  Reminder: the real acceptance test is connecting with the phone's"
echo "  wifi OFF, over cellular. Passing on wifi only proves the LAN works."
