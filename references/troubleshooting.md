# Troubleshooting

Symptom → cause → fix. Every entry here is a real failure observed in practice,
not a hypothetical.

## Split the problem first

Before guessing, isolate the layer. This one question saves the most time:

> Does `ssh mac` work, but `mosh mac` doesn't?

- **Neither works** → network or auth. Check Tailscale peers, then the sshd log.
- **`ssh` works, `mosh` doesn't** → mosh-specific: locale or UDP.
- **Both work, session doesn't persist** → tmux.

Watching `~/.pocket/sshd/sshd.log` from the Mac while the user taps on the phone
is far faster than reading errors off a small screen.

---

## `ssh-copy-id` fails / asks for a password that never works

**Cause:** by design. The pocket terminal runs a *non-root* sshd, which has no
privileged PAM access, so password authentication is impossible — and
`ssh-copy-id` needs exactly that to bootstrap.

**Fix:** transfer the public key another way (see `onboard-device.md`). This is
not a bug to work around; it's the tradeoff for needing no admin password.

---

## `mosh-server needs a UTF-8 native locale to run`

**Cause:** mobile SSH clients frequently send no `LANG`, and the server's default
is `C`/US-ASCII. The error text points at the *client* environment, which makes
it read like a phone problem. It isn't.

**Fix:** force a locale server-side, in both places (they cover different launch
paths — `.zshenv` for shells, `SetEnv` for the sshd exec path):

```bash
# ~/.zshenv
export LANG="${LANG:-en_US.UTF-8}"
export LC_CTYPE="${LC_CTYPE:-en_US.UTF-8}"
```
```
# sshd_config — sshd honours ONLY THE FIRST SetEnv line. Everything must share
# it; a separate "SetEnv LANG=..." line below is silently ignored, which looks
# correct in the file and still fails at runtime.
SetEnv PATH=/Users/you/.local/bin:/usr/local/bin:/usr/bin:/bin LANG=en_US.UTF-8 LC_CTYPE=en_US.UTF-8
```

---

## `TERM environment variable not set`

**Cause:** launching mosh from a non-tty context.

**Fix:** `export TERM=xterm-256color`. The `pocket` helper already does this.

---

## `could not get canonical name for mac` / `Did not find remote IP address`

**Cause:** almost always **`mosh mac` typed while already connected to the Mac.**
The host alias only exists in the phone's client config; the Mac has never heard
of it.

**Fix:** not a fault. Teach the prompt distinction — `blink>` is the phone,
`user@Their-MacBook %` is the Mac. This error is confusing enough that users
reasonably conclude the setup broke, so say plainly: "you're already there."

---

## mosh hangs; `Nothing received from server on UDP port 600xx`

**Cause:** UDP isn't reaching the Mac. Usually a userspace-mode Tailscale
daemon, which proxies inbound TCP but not reliably UDP.

**Fix:** use the system Tailscale app (`brew install --cask tailscale-app`) and
fully remove any userspace daemon — see the ghost-node entry below. Confirm the
path is direct:

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale ping <phone-ip>
# want: "pong from ... via <addr>:41641"   (direct)
# "via DERP" = relayed: works, but slower
```

---

## Mac appears twice on the tailnet; real node renamed `<host>-1`

**Cause:** two `tailscaled` instances registered separately — typically a
leftover userspace daemon alongside the GUI app.

**Fix:** `launchctl unload` is **not enough** — a plist with `RunAtLoad` will
resurrect at next login. Delete it:

```bash
launchctl unload ~/Library/LaunchAgents/com.pocket.tailscaled.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.pocket.tailscaled.plist
pkill -f "tailscaled --tun=userspace"
```

Then delete the stale machine in the Tailscale admin console to free the name.

---

## `The Tailscale SSH server does not run in sandboxed Tailscale GUI builds`

**Cause:** `tailscale set --ssh=true` is unsupported in the cask/App Store build.

**Fix:** none — don't go down this path. It looks like it would eliminate SSH
keys entirely, which makes it tempting; it won't work with this install.

---

## `Socket error: Operation timed out` on the phone

**Cause, nearly always:** the phone is signed into Tailscale but the **VPN is not
switched on**, so it has no route to the Mac. Signing in is not the same as
connecting — iOS installs Tailscale as a VPN profile that must be toggled, and
iOS drops it after the phone has been idle.

This is the highest-value entry in this file. The error says "socket" and
"timed out", which reads like a firewall or port problem and sends people
hunting through sshd config — where nothing is wrong.

**Diagnose from the Mac**, which is unambiguous:

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale status
```

If the phone's line reads `offline, last seen 2h ago`, that's it. No packet ever
left the phone. Nothing on the Mac is at fault, so don't touch it.

**Fix:** open Tailscale on the phone, toggle it on, confirm it says *Connected*
and iOS shows the VPN badge. Then enable **VPN On Demand** — without it this
recurs every time the phone sleeps, and the setup feels flaky when it's fine.

**Distinguish from auth failure.** A timeout means the phone never arrived. If
you instead see `authFailed(methods: [SSH.AuthAgent])`, the phone *did* reach the
Mac and the network is fine — that's a key problem, and the Mac's sshd log will
show the attempt. Timeout = network; authFailed = keys. Don't confuse them.

---

## Phone can't reach the Mac at all after it was working

Check in this order:

1. **Phone's Tailscale VPN toggled off.** See the entry above — most common of
   all, and it looks like a network fault.
2. **Mac asleep or dead.** `pmset -g custom` — want `sleep 0` on AC. Lid-closed
   additionally needs `disablesleep 1` (requires `sudo`, so the user runs it).
   Also confirm it is genuinely *charging*, not merely "AC attached" — an
   underpowered adapter drains the machine while looking plugged in:

   ```bash
   ioreg -rn AppleSmartBattery | grep -oE '"Watts"=[0-9]+|"IsCharging" = [A-Za-z]+'
   ```

   Under ~30W on a laptop means it will die regardless of what the icon says.
3. **Tailscale logged out** on either end: `Tailscale status` → "Logged out".
4. **sshd not running:** `launchctl list | grep com.pocket.sshd`.
5. **Low Power Mode** on the phone suspending Tailscale.

---

## iPhone Mirroring problems

| Symptom | Meaning |
|---|---|
| "iPhone in Use — Lock your iPhone to connect" | The phone is unlocked/in hand. Mirroring refuses. Ends the moment the user picks it up. |
| "Timed Out ... due to iPhone use while connecting" | Same cause; lock and retry. |
| Wrong iPhone appears | Mirroring binds to **one** device with no picker. A different phone (e.g. a spare) is effectively unreachable. **Confirm the model before configuring anything.** |
| Typed text arrives mangled (`gconfi` for `config`) | Characters drop over the link. Type, then read the field back before committing. |
| Suddenly on the home screen | A tap landed on the home indicator. Stay away from the bottom edge. |

---

## Blink specifics

- **No `ssh-keygen`.** Commands are `ssh, mosh, code, build, config`. Keys come
  from the `config` UI only.
- **Host form's top-left is Discard, not Back.** Leaving that way silently
  discards the entry. Save is top-right.
- `Cmd+T` opens a new local shell — useful for reaching `blink>` without killing
  an active remote session.

---

## Session didn't persist

**Cause:** connected outside tmux.

**Check:** `tmux ls` should show `pocket` and, on reconnect, the *same* creation
timestamp — that proves reattachment rather than a new session. A tmux status bar
at the bottom of the phone screen is the user-visible confirmation.

**Escape hatch:** if auto-attach ever traps someone, connect with
`POCKET_NOTMUX=1` for a plain shell.

---

## sshd log is stale / no entries for a connection that clearly happened

**Cause:** `sshd -D` alone logs to **syslog**, not stderr, so launchd's
`StandardOutPath` captures nothing. The file keeps whatever it had from an
earlier run and silently stops growing. The daemon still holds the file open, so
`lsof` looks correct and everything appears fine.

**Why it matters more than it sounds:** the log is the tool you use to split
"the phone never arrived" (network) from "the phone arrived and was rejected"
(keys). When it goes blind you lose that split, and — worse — an empty log reads
as *proof of absence*. It isn't. Don't conclude a device never connected from a
log you haven't verified is live.

**Check** it's actually recording before trusting it:

```bash
B=$(wc -c < ~/.pocket/sshd/sshd.log)
ssh -p 2222 -o BatchMode=yes -o ConnectTimeout=3 nobody@127.0.0.1 true 2>/dev/null
sleep 2; A=$(wc -c < ~/.pocket/sshd/sshd.log)
[ "$A" -gt "$B" ] && echo "logging live" || echo "BLIND"
```

The rejected `nobody` login is the point — it proves writes are landing.

**Fix:** add `-e` to `ProgramArguments` before `-D`, then reload the agent.
`setup-mac.sh` does this; installs created before this fix need it added by hand.
