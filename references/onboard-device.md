# Onboarding a device

Read this when adding a phone or tablet to an existing pocket terminal. Assumes
the Mac side is already done (`scripts/setup-mac.sh` + Tailscale signed in).

## Order matters

Do the free, reversible steps first and *verify the network path before anyone
spends money*. If Tailscale can't reach the Mac, a paid terminal app won't help.

1. Tailscale on the device (free)
2. Confirm the peer appears and pings — from the Mac
3. Terminal app
4. Key generation + transfer
5. Host entry
6. Connect, then the cellular test

## 1. Tailscale

Same account as the Mac. **This may not be the same as their Apple ID** — worth
saying out loud, because mixing them up is a common stall.

Confirm from the Mac rather than trusting the phone's UI:

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale status
/Applications/Tailscale.app/Contents/MacOS/Tailscale ping <phone-tailnet-ip>
```

A response reading `pong from <host> via <addr>:41641` means a **direct**
peer-to-peer UDP path — mosh will work well. `via DERP` means it's relaying:
still functional, but higher latency, and worth mentioning.

## 2. Terminal app

**Blink Shell, Build & Code** — Blink Shell, Inc, App Store ID `1594898306`,
free to install, subscription for the paid tier, requires **iOS 17.6+**.

- Verify against Apple's catalog rather than guessing at availability or price:
  `curl -s "https://itunes.apple.com/lookup?id=1594898306"`
- **Decoy warning:** searching "blink" surfaces *Blink Home Monitor* (a camera
  app) far more prominently. Confirm the developer is "Blink Shell, Inc" and the
  category is Developer Tools.
- A spare phone that's been in a drawer may be below iOS 17.6. Check
  Settings → General → Software Update *before* the App Store dead-ends them.

Free alternatives: **Moshi** (speaks mosh, iOS 18+), **Termius** (no mosh —
useful to prove the path, but the latency win is lost).

## 3. Keys

Generate **on the device**. Prefer a Secure Enclave key: the private half cannot
be extracted, which is strictly better than a file-based key on a phone.

The tradeoff, which must be stated to the user: **a Secure Enclave key cannot be
copied to another device.** Every phone gets its own key and its own line in
`authorized_keys`. That's also good hygiene — revoke one without touching the
others.

In Blink: `config` → **Keys & Certificates** → Secure Enclave → **Generate New**.

**Name it `id_ecdsa`.** Blink treats that name as the default key and will offer
it automatically, which removes a whole configuration step and a whole class of
"why is it not using my key" failures.

Note: Blink's shell has **no `ssh-keygen`** — its commands are `ssh, mosh, code,
build, config`. Keys only come from the `config` UI.

## 4. Getting the public key to the Mac

This is the fiddliest part, because the obvious routes fail quietly. Try in this
order:

| Route | Reality |
|---|---|
| **iCloud Drive** (Share → Save to Files → iCloud Drive) | Most reliable **when it's available** — read it on the Mac at `~/Library/Mobile Documents/com~apple~CloudDocs/`. Blink names the file something generic like `text 2.txt`. |
| **AirDrop** | The route to use when iCloud Drive isn't offered. Lands in `~/Downloads`. Requires the Mac's AirDrop set to **Everyone** — on "Contacts Only" the phone reports "No People Found". That's a security setting, so the user changes it, and should change it back after. |
| Paste into the chat | Fine — a *public* key is not a secret. Good fallback. |
| Universal Clipboard | Often silently fails. Don't build the flow around it. |
| Reading it off the screen | Last resort. ECDSA keys are long and truncated in the UI. |

**If "Save to Files" shows no iCloud Drive option**, the device is signed into
the App Store but not iCloud — a deliberate and sensible choice for a spare
phone, since it keeps Messages, Photos, and Keychain off a device whose only job
is running a terminal. Don't treat it as misconfiguration and don't push the user
to enable iCloud for it. Go to AirDrop instead.

Then install and validate — never append blind:

```bash
F="$HOME/Downloads/<file>"                 # or the iCloud Drive path
ssh-keygen -l -f "$F"                      # confirm it parses as a public key
cat "$F" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
ssh-keygen -lf ~/.ssh/authorized_keys      # confirm what's now trusted
rm "$F"                                    # don't leave it lying around
```

### Label the key, immediately

Blink comments every key it generates `user@iphone`, regardless of device. With
two phones onboarded you get two identical-looking entries and no way to tell
which is which — so revoking one later means guessing, and guessing wrong locks
out the wrong phone.

Rewrite the comment as you install it:

```bash
sed -i '' "s|user@iphone$|iphone-11|" ~/.ssh/authorized_keys   # last line only if it's the new one
awk '{print $NF}' ~/.ssh/authorized_keys                       # verify labels are distinct
```

Safer for the general case: append with the label already attached, e.g.
`printf '%s %s %s\n' "$type" "$b64" "iphone-11" >> ~/.ssh/authorized_keys`.

## 5. Host entry

In Blink: `config` → **Hosts** → **Add new Host**

| Field | Value |
|---|---|
| Alias | `mac` |
| HostName | the Mac's tailnet IP (more reliable than MagicDNS on mobile) |
| Port | `2222` |
| User | the Mac username |
| Key | leave as default if the key is named `id_ecdsa` |

**Trap:** on Blink's host form the top-left control is **Discard**, not "back".
Leaving via that arrow silently throws the entry away. Save is top-**right**.
Also avoid tapping fields at the very bottom of the screen — that's the home
indicator zone and it swipes you out of the app.

## 6. Connect

```
ssh mac       # prove auth first — simpler, fewer moving parts
mosh mac      # then the real thing
```

On first connect Blink shows a host key fingerprint. **Verify it** against the
Mac instead of telling the user to accept:

```bash
ssh-keygen -lf ~/.pocket/sshd/host_ed25519_key.pub
```

Confirm server-side that mosh is genuinely in play rather than trusting the
screen — a successful `ssh` looks nearly identical:

```bash
pgrep -fl mosh-server
lsof -nP -iUDP | grep mosh     # expect a bind on 600xx at the tailnet IP
tmux ls                        # expect one session, reattached not duplicated
```

## 7. The test that actually matters

Wifi **off** on the phone, then `mosh mac` over cellular. You usually cannot do
this yourself — killing the phone's wifi tends to kill your control channel too.
Hand it over explicitly and say why it matters.
