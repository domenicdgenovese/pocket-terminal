#!/usr/bin/env python3
"""selftest-bot.py — exercise every pocket-bot path without sending anything.

Run after ANY change to pocket-bot. Drives handle() directly with say()
intercepted, so it tests the real code without messaging Telegram and without
making the user the test harness.

Covers the failures that actually happened in practice: commands not resolving
because the login shell wasn't loaded, the destructive-command guard failing to
arm, and background jobs never reporting back.

    python3 scripts/selftest-bot.py [project-dir]
"""

import importlib.machinery
import importlib.util
import os
import sys
import time

BOT = os.path.expanduser("~/.local/bin/pocket-bot")
if not os.path.exists(BOT):
    print(f"pocket-bot not installed at {BOT}")
    sys.exit(1)

spec = importlib.util.spec_from_loader(
    "pb", importlib.machinery.SourceFileLoader("pb", BOT))
pb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pb)

SENT = []
pb.say = lambda text, quiet=False: SENT.append(text)   # intercept; send nothing
pb.save_state = lambda s: None

CWD = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~")
st = {"cwd": CWD, "offset": 0, "paused": False, "pending": None}

passed = failed = 0


def check(name, cond, detail=""):
    global passed, failed
    cond = bool(cond)
    if cond:
        passed += 1
    else:
        failed += 1
    print(f"  {'PASS' if cond else 'FAIL'}  {name}"
          + (f"  — {detail}" if detail and not cond else ""))


r = pb.handle("/help", st)
check("/help returns the menu", "Talk to your Mac" in (r or ""), repr(r)[:80])

r = pb.handle("/where", st)
check("/where reports a directory", os.path.basename(CWD) in (r or ""), repr(r)[:80])

r = pb.handle("/nonsense", st)
check("unknown command is rejected", "unknown" in (r or "").lower())

r = pb.handle("/jobs", st)
check("/jobs idle", "nothing running" in (r or ""))

# The guard must ARM (store the command) rather than run it.
r = pb.handle("/run rm -rf /tmp/does-not-exist", st)
check("destructive command is held for confirmation",
      "destructive" in (r or "").lower() and st["pending"], repr(r)[:80])
r = pb.handle("no", st)
check("declining cancels it", "cancel" in (r or "").lower())
check("nothing left pending", st["pending"] is None)

pb.handle("/pause", st)
r = pb.handle("do something", st)
check("/pause blocks work", "paused" in (r or "").lower())
pb.handle("/resume", st)

# Real background job. This is the one that catches PATH problems: node lives
# under nvm and only exists if .zshrc was sourced.
SENT.clear()
r = pb.handle("/run node --version", st)
check("job starts and returns immediately", "started" in (r or "").lower(), repr(r)[:80])

deadline = time.time() + 60
while time.time() < deadline and not any("exit" in s for s in SENT):
    time.sleep(1)

check("background job reports back", any("exit" in s for s in SENT), f"got {SENT}")
check("node resolves via the login shell", any("exit 0" in s for s in SENT),
      f"got {SENT} — if this fails, .zshrc isn't being sourced")

print()
print(f"  {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
