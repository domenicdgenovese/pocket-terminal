# pocket-terminal

A [Claude Code](https://claude.com/claude-code) skill for turning a phone into a
real terminal onto your Mac — low-latency, and with a session that survives
losing signal.

```
phone ──► Tailscale (private mesh) ──► Mac ──► mosh ──► tmux ──► claude
```

You can't run Claude Code natively on iOS — there's no real Node runtime or
filesystem for it. So the Mac does the work and the phone drives it. That's not
a workaround; it's the correct shape.

## The part worth reading

The happy path takes about fifteen minutes. What takes four hours is the traps.
This skill exists because of them:

**`ssh-copy-id` can never work here.** The setup deliberately runs a *user-level*
sshd on port 2222 so it needs no admin password. But a non-root sshd has no
privileged PAM access, so password authentication is impossible — and
`ssh-copy-id` needs exactly that to bootstrap itself. Every device's public key
has to arrive by another route.

**mosh fails with an error that blames the wrong machine.** `mosh-server` refuses
to start without a UTF-8 locale, and mobile SSH clients routinely send no `LANG`
at all. The message points at the client environment, so it reads like a phone
bug. It isn't.

**And `sshd` honours only the *first* `SetEnv` line.** Split `PATH` and `LANG`
across two lines and the second is silently ignored — the config looks correct
and still fails at runtime. This one bit us twice, including once while writing
this skill.

**Tailscale SSH looks like it removes the whole key dance. It doesn't.**
`tailscale set --ssh=true` fails on the Homebrew cask build: *"The Tailscale SSH
server does not run in sandboxed Tailscale GUI builds."*

**Userspace-mode Tailscale quietly breaks the thing you installed it for.** It
proxies inbound TCP but not reliably UDP — and UDP is exactly what mosh needs.
Worse, `launchctl unload` doesn't remove it; `RunAtLoad` resurrects it at next
login, leaving a ghost node and renaming your real one to `<host>-1`.

**Universal Clipboard and AirDrop both fail silently** when moving the public key
across. iCloud Drive is the route that actually works.

**Blink's back button is Discard.** Top-left on the host form throws the entry
away without warning. Save is top-right.

Full list in [`references/troubleshooting.md`](references/troubleshooting.md).

## Install

```bash
git clone https://github.com/<you>/pocket-terminal ~/.claude/skills/pocket-terminal
```

Claude Code picks it up automatically. Then just describe what you want —
"set up my old iPhone as a terminal into this Mac" — and it'll pull the skill in.

## Use directly

```bash
~/.claude/skills/pocket-terminal/scripts/setup-mac.sh     # Mac side, no sudo
~/.claude/skills/pocket-terminal/scripts/verify-pocket.sh # check every layer
```

Set `POCKET_PROJECT` if you want to land somewhere other than `$HOME`:

```bash
POCKET_PROJECT=~/code/my-project ~/.claude/skills/pocket-terminal/scripts/setup-mac.sh
```

It's idempotent, but it *rewrites* `~/.local/bin/pocket` each run — so pass the
variable every time or a re-run will quietly reset your landing directory.

`verify-pocket.sh` tests each layer independently,
which is the whole point — it turns one opaque failure on a small screen into a
specific answer: network, auth, mosh, or session.

## What you end up with

Two words on the phone:

```
mosh mac
```

...and you're in your project on the Mac with Claude Code ready. Close the app,
lose signal, walk into a tunnel — the tmux session keeps running and you land
right back in it.

## Requirements

- macOS host (uses `launchd`, and iPhone Mirroring if you want Claude to drive
  the phone for you). Intel and Apple Silicon both handled.
- [Homebrew](https://brew.sh)
- [Tailscale](https://tailscale.com) — the **system app**, free tier is fine.
  Note the cask runs a pkg installer, so this one step *does* prompt for your
  admin password. `setup-mac.sh` itself never does.
- A mosh-capable terminal: [Blink Shell](https://blink.sh) (free to install),
  or Moshi. Termius works for SSH but has no mosh, so you lose the anti-lag.

## Status

Built and verified end-to-end on one machine (Intel Mac, macOS 26, iPhone 16).
Apple Silicon paths are handled via `brew --prefix` but **have not been tested on
real hardware yet** — if you run it there, an issue either way is genuinely
useful.

## License

MIT — see [LICENSE](LICENSE).
