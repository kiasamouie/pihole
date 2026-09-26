# VOICE BLOCK VERIFICATION — physical steps (voice policy v2)

Goal: prove the Samsung's cloud voice is blocked while everything else works,
with hard network evidence captured automatically.

Preconditions (all already true, re-check in 30 s):

```bash
cd <repo-root>
sudo scripts/tvguard-status.sh        # PRIVACY=standard-no-voice, MODE=monitor
scripts/health-check.sh               # all green
```

## What YOU do (physical, on the TV) — everything else is automatic

### 1. Turn the TV ON and wait ~30 s at the home screen

Confirm the home screen loads normally (apps visible, TV Plus list present).
If the home screen is broken, STOP and run the rollback (below) — do not
continue the voice test on a broken baseline.

### 2. Run the proof capture (ONE command, 7 minutes)

```bash
cd <repo-root>
sudo scripts/voice-proof-capture.sh
```

The script prints a countdown:

- **first 2 minutes (PRE):** get the remote, sit in front of the TV.
- **next 2 minutes (ACTIVE):** press the voice button and ask, in order,
  waiting ~15–20 s between each (note the TV's clock time when you ask):
  1. **"What is the weather in Tokyo right now?"** — decline the location
     prompt if it appears.
  2. **"What is the weather in Sydney right now?"**
  3. **"What is the current price of Bitcoin?"**
- **last 3 minutes (POST):** leave the TV alone.

### 3. Expected results on the TV

| Question | Expected | What it proves |
|---|---|---|
| Tokyo weather | **fails** (timeout, "cannot reach the voice service", error, or no answer) | the Bixby user plane is cut |
| Sydney weather | **fails** | same, second confirmation |
| Bitcoin price | **fails** | fresh cloud data cannot reach the TV |
| home screen / apps / playback (tested separately) | work normally | no collateral breakage |

Local/simple commands ("open the input", "volume up") may still work — that
is expected and fine. **Any of the three cloud answers succeeding = the test
fails**; in that case run the capture again and report the capture directory
(it contains the new destination that slipped through).

### 4. After the capture finishes

The script prints the capture directory
(`captures/voice-discovery/voice-proof-<timestamp>/`). Report:

1. What the TV displayed for each of the three questions (and the TV clock
   time of each).
2. The capture directory name.

I (the agent) will then read `summary.md` / `candidates.csv` / `timeline.csv`
from that directory and confirm:

- no successful connection to any aibixby.com / Bixby infrastructure
  (blocked attempts appear as `TVGUARD-PRIVACY` log lines / Pi-hole DENYLIST
  entries, not as new flows);
- YouTube/Prime/keep-list traffic in the same window is normal (proves the
  NAT path and keep list are intact);
- if anything voice-related still resolved, it is identified and added in the
  next iteration (research → exact entry → mock test → re-apply →
  `sudo scripts/privacy-reset-tv-voice-state.sh` → repeat this protocol).

## Rollback (if anything essential breaks)

```bash
sudo scripts/privacy-policy-disable.sh
```

Removes only the privacy layer (firewall sets + Pi-hole group + regex);
gateway/NAT/Pi-hole/MONITOR/UFW/Docker all remain. TV Internet returns
immediately.
