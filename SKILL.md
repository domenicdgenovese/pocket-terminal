---
name: pocket-terminal
description: >
  Set up or extend a "pocket terminal" — a phone or tablet that connects into a
  Mac over Tailscale and runs Claude Code in a persistent tmux session via mosh.
  Covers first-time Mac-side setup, onboarding an additional device, and
  diagnosing a broken connection. Use this skill whenever the user wants to code,
  run Claude Code, or reach their Mac from a phone or iPad; mentions Blink Shell,
  mosh, Tailscale, tailnet, MagicDNS, Termius, or a "pocket"/"remote"/"mobile"
  dev setup; asks to add a second or spare phone to an existing setup; or reports
  that connecting from their phone stopped working. Also use it for adjacent
  asks like "let me check on a build from my phone", "I want to work from my
  couch/bed/car", or "make my iPhone a terminal" — even when they don't name any
  of these tools.
---

# Pocket Terminal

Turn a phone into a real window onto a Mac: a low-latency terminal for Claude
Code, backed by a session that survives disconnects.

## The architecture, and why

```
phone ──► Tailscale (private encrypted mesh) ──► Mac (always on)
                                                  │
                                          mosh ──► tmux "pocket" ──► claude
```

Claude Code cannot run natively on iOS — there is no real Node runtime or
filesystem for it. So the Mac does the work and the phone drives it. This is not
a compromise; it is the correct shape for this problem.

Each layer earns its place:

- **Tailscale** — private mesh, no port forwarding, works on cellular. Never
  expose SSH to the public internet.
- **mosh** — local echo and roaming. This is the single biggest anti-lag lever
  that exists for a mobile terminal, and the reason plain SSH feels worse.
- **tmux** — the session outlives the connection. A dropped phone signal must
  not kill a running agent.

## Before doing anything: what you cannot do

You will hit hard walls. Recognize them early and hand off cleanly instead of
burning the user's time discovering them mid-flow:

- **Passwords, Apple ID auth, App Store installs, purchases/subscriptions.**
  Never type a password, and never pull one from a password manager, even when
  the user explicitly offers. Get the flow to the exact prompt, then hand over.
- **`sudo`.** You cannot type an admin password. The Mac setup here is
  *deliberately designed to need zero admin rights* — see below.

Tell the user about these up front, once, in a sentence. Do not re-litigate them
each time one appears.

## Phase A — Mac side (no admin password required)

Run `scripts/setup-mac.sh`. It is idempotent; safe to re-run.

The key design decision: **run a user-level sshd on port 2222** instead of
enabling system Remote Login on 22. Remote Login needs `sudo`. A per-user sshd
does not, and it works identically for this purpose.

That choice has one consequence worth internalizing, because it will bite:

> A non-root sshd **cannot do password authentication** (no privileged PAM
> access). So **`ssh-copy-id` can never work.** Every device's public key must be
> placed into `~/.ssh/authorized_keys` by another route. See Phase B.

Tailscale must be the **system app**, not userspace mode:

```bash
brew install --cask tailscale-app
```

Userspace mode (`tailscaled --tun=userspace-networking`) proxies inbound *TCP*
to localhost but is unreliable for the *UDP* that mosh needs — and Jump Desktop's
Fluid protocol is UDP too. If a userspace daemon was used as a temporary
workaround, remove its LaunchAgent entirely (`launchctl unload` alone is not
enough — `RunAtLoad` will resurrect it at next login) or the tailnet ends up with
a duplicate ghost node and the real one gets renamed `<host>-1`.

Then have the user sign in. You can generate the auth URL yourself and open it:

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale login --hostname=<name>
open "<the https://login.tailscale.com/a/... URL it prints>"
```

**Tailscale SSH (`--ssh`) is not an option here.** The cask build refuses:
"The Tailscale SSH server does not run in sandboxed Tailscale GUI builds."
Don't suggest it; it looks like it would remove the whole key dance, and it
won't.

### Locale — fix this before it bites

`mosh-server` refuses to start without a UTF-8 locale, and mobile SSH clients
frequently send no `LANG` at all. The failure message is long and points at the
client, so it reads like a client bug. The setup script forces a locale in both
`~/.zshenv` and the sshd config. Leave both in place — they cover different
launch paths.

## Phase B — onboarding a device

Full walkthrough with UI specifics: **`references/onboard-device.md`**. Read it
when actually doing this; it has the Blink menu paths and the traps.

The shape:

1. Install **Tailscale** (free) and a mosh-capable terminal. **Blink Shell,
   Build & Code** (Blink Shell, Inc, App Store ID `1594898306`) is free to
   install with a paid tier. Free alternatives: **Moshi** (has mosh) or
   **Termius** (no mosh — proves the path, but you lose the anti-lag).
   Watch for decoys: "Blink Home Monitor" is an unrelated camera app.
2. Sign into Tailscale with the **same account as the Mac** — note this may
   differ from the Apple ID used for the App Store.
3. Generate a key **on the device**. Prefer Secure Enclave: the private key
   physically cannot leave the phone. The consequence is that **each device needs
   its own key** — you cannot copy one phone's key to another.
4. Move the **public** key to the Mac and append it to `~/.ssh/authorized_keys`.
   Transfer routes, in order of reliability — see the reference file, since the
   obvious ones fail more often than not.
5. Save a host entry, then verify.

Verify the host key fingerprint on first connect rather than telling the user to
accept blindly — you can print the real one from the Mac:

```bash
ssh-keygen -lf ~/.pocket/sshd/host_ed25519_key.pub
```

## Verifying

Run `scripts/verify-pocket.sh`. It checks each layer independently, which is what
makes debugging fast: it isolates *network* vs *auth* vs *mosh* vs *session*
instead of leaving the user staring at one opaque error on a small screen.

The acceptance test is **not** a successful connection on wifi. It is a
successful connection with **wifi off, over cellular**. Until that passes, the
setup has only been proven on the LAN. Push for it — this is the step people skip
and then discover the gap when they actually need it.

Note you generally cannot run that test yourself: turning off the phone's wifi
usually severs whatever channel you're using to control it. Hand it over
explicitly.

## Driving the phone directly (optional, macOS)

iPhone Mirroring can put the phone on screen so you can operate it. Real limits:

- It binds to **one** iPhone — whichever is paired. There's no device picker;
  switching means revoking access to the current phone. If the target is a
  *different* phone (a spare), you likely cannot reach it at all. **Confirm which
  device you're looking at before touching anything** — configuring the user's
  daily driver when they meant a spare is a real and costly mistake.
- It refuses to connect while the phone is in use: "Lock your iPhone to connect."
  Any time the user picks up the phone, your session ends.
- Typing over the link **drops characters**. Type, then read the field back
  before committing. Assume nothing landed correctly.
- Avoid clicking near the bottom edge — you'll hit the home indicator and get
  swiped out of the app.

If you can't drive it, guiding the user while you watch the Mac-side logs is
genuinely effective: it splits every failure into network vs config immediately.

## Talking to the user

Match their vocabulary. Someone wiring a tailnet at 1am is often not a network
engineer, and a wall of jargon at the finish line undoes the win. Two things
worth stating plainly at the end, because they cause the most post-setup
confusion:

- **Which prompt means which machine.** `blink>` is the phone (type `mosh mac`
  here). `user@Their-MacBook %` is the Mac (type `claude` here). Running
  `mosh mac` while already connected produces a confusing "could not get
  canonical name" error that looks like a broken setup but just means
  "you're already there."
- **The session persists.** Closing the app loses nothing.

Flag any trial that auto-renews.

## Reference files

- **`references/onboard-device.md`** — device walkthrough, key transfer routes,
  Blink UI specifics. Read before doing Phase B.
- **`references/troubleshooting.md`** — symptom → cause → fix. Read when
  something fails, or when the user reports a previously-working setup broke.
