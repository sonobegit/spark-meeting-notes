# spark-transcripts

Daily automation that pulls **Spark +AI meeting-note summaries** from the Spark
mail app and commits them to the [`element-research`](#the-content-repo) git repo.
Runs unattended via `launchd` on macOS.

This repo is the **tooling** (script + launchd job + installer). The transcripts
themselves live in a separate **content** repo (`element-research`).

---

## What it does

Once a day (22:00 local time) it:

1. Wakes Spark Desktop (the `spark` CLI is a thin IPC client to the app).
2. Lists meeting notes via `spark meetings`, newest first.
3. For each meeting not yet seen, fetches the **summary only**
   (`spark meeting <id>`, no `--transcript`) and writes it to
   `element-research/transcripts/<date>-<slug>.md`.
4. Records processed IDs in a **per-user** dedup manifest.
5. Rebases on the remote, commits new transcripts, and pushes.

It is idempotent: nothing new ⇒ no commit. A push that failed on a previous run
is retried on the next run even if that run found nothing new.

---

## How it works (architecture)

```
launchd (22:00 daily)
  └─ ~/.local/bin/transfer-spark-transcripts.sh
       ├─ open -a "Spark Desktop"      # ensure the app is running
       ├─ spark accounts               # readiness probe (waits up to ~60s)
       ├─ spark meetings               # list IDs (own account only — see Caveats)
       ├─ spark meeting <id>           # fetch summary, dedup via manifest
       └─ git pull --rebase → commit → push   # into element-research
```

- **Spark CLI**: `/usr/local/bin/spark` (override with `SPARK_BIN`). It only
  talks to the locally running Spark Desktop, so the app must be installed and
  signed in.
- **Schedule**: `StartCalendarInterval` at 22:00. If the Mac is asleep at 22:00,
  launchd runs the job once on next wake (no multi-day catch-up — harmless here
  because dedup makes every run idempotent).
- **Logs**: `~/Library/Logs/spark-transcripts.log` (appended; not rotated).

---

## Repository layout

| File | Purpose |
|------|---------|
| `transfer-spark-transcripts.sh` | The job. Portable (`$HOME`, env overrides). |
| `install.sh` | Deploys the script + generates & loads the launchd plist for the current user. |
| `nl.sonobe.spark-transcripts.plist.template` | Reference plist for manual installs. |
| `README.md` | This file. |

---

## Prerequisites

- **macOS** (uses `launchd`).
- **Spark Desktop**, installed and signed in to the user's account.
- The **`spark` CLI** at `/usr/local/bin/spark` (or set `SPARK_BIN`).
- A clone of **`element-research`** (the content repo) with push access.
- `git`, `bash`, `awk`, `sed` (stock on macOS).

### The content repo

By default the script expects the clone at:

```
~/Development/sonobe-element-root/element-research
```

Clone it there, or point `SPARK_TRANSCRIPTS_REPO` / the `install.sh` argument at
another location. Transcripts are written to its `transcripts/` subfolder.

---

## Quick start

```bash
git clone <this-repo-url> ~/Development/spark-transcripts
cd ~/Development/spark-transcripts

# Default repo location:
./install.sh

# …or a custom element-research clone location:
./install.sh /path/to/element-research

# Verify with a manual run (don't wait for 22:00):
bash ~/.local/bin/transfer-spark-transcripts.sh
tail -n 20 ~/Library/Logs/spark-transcripts.log
```

`install.sh` is idempotent — re-run it after pulling updates to redeploy.

### Manual install (alternative)

1. Copy `transfer-spark-transcripts.sh` to `~/.local/bin/` and `chmod +x` it.
2. Copy `nl.sonobe.spark-transcripts.plist.template` to
   `~/Library/LaunchAgents/nl.sonobe.spark-transcripts.plist`, replacing
   `__SCRIPT_PATH__` and `__LOG_PATH__` with **absolute** paths (launchd does not
   expand `~`/`$HOME`). Set `SPARK_TRANSCRIPTS_REPO` in the env block if your
   clone is not at the default path.
3. `launchctl load ~/Library/LaunchAgents/nl.sonobe.spark-transcripts.plist`

---

## Configuration

| Env var | Default | Meaning |
|---------|---------|---------|
| `SPARK_TRANSCRIPTS_REPO` | `~/Development/sonobe-element-root/element-research` | Path to the element-research clone. |
| `SPARK_BIN` | `/usr/local/bin/spark` | Path to the spark CLI. |

Change the schedule by editing `StartCalendarInterval` in the plist (then reload
the agent).

---

## Multi-writer / team setup

Several teammates can feed the **same** `element-research` repo, each running
their own copy of this job on their own Mac. The `spark` CLI only sees the
locally signed-in account, so each person captures **their own** meetings. The
script is built for this:

- **Per-user manifest** — `transcripts/.processed-ids-<username>`, so no two
  installs fight over one dedup file. Meeting IDs from different Spark accounts
  never collide.
- **Rebase before commit** — `git pull --rebase --autostash` lands teammates'
  transcripts first and keeps each push a clean fast-forward.
- **Push decoupled from new work** — any local commit ahead of `origin` is
  pushed, including one stranded by an earlier failed push.

To onboard a teammate: install Spark Desktop + the `spark` CLI, clone
`element-research`, then run `./install.sh`. Done.

---

## Caveats about Spark (read before extending)

- **Meeting notes are stored in the cloud** (in the user's Spark account;
  transcription/summarisation runs via Azure OpenAI). The audio stream may be
  retained by the AI provider for up to ~30 days for abuse monitoring.
- **The CLI only lists the signed-in user's own meetings.** `spark meetings` has
  no `team:`/`shared:` filter and its help says it lists notes "recorded by
  Spark" (this instance). Do **not** assume this job can pull a teammate's
  meetings even when you share a Spark Team — have each teammate run their own
  install instead (see above).
- **Consent**: inform participants before recording/transcribing meetings (legal
  requirement in many EU jurisdictions).

---

## Operations & troubleshooting

```bash
# Is the agent loaded?
launchctl list | grep spark-transcripts        # col 2 = last exit code (0 = ok)

# Run now, watch output
bash ~/.local/bin/transfer-spark-transcripts.sh
tail -n 40 ~/Library/Logs/spark-transcripts.log

# Reload after editing the plist
launchctl unload ~/Library/LaunchAgents/nl.sonobe.spark-transcripts.plist
launchctl load   ~/Library/LaunchAgents/nl.sonobe.spark-transcripts.plist
```

Common log lines and what they mean:

| Log line | Meaning / action |
|----------|------------------|
| `Spark Desktop did not become reachable within ~60s` | App not installed / not signed in / slow launch. Open Spark manually and retry. |
| `spark CLI not found at …` | Install the CLI or set `SPARK_BIN`. |
| `repo not found at …` | Clone element-research or set `SPARK_TRANSCRIPTS_REPO`. |
| `warn: pull --rebase failed` | Remote diverged or offline; the run still tries to push. Resolve manually if it persists. |
| `warn: git push failed …` | Usually credentials in launchd's minimal env (SSH key/keychain not reachable). Confirm `git push` works from a plain shell; the commit retries next run. |
| `nothing to push` | Up to date — normal. |

### Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/nl.sonobe.spark-transcripts.plist
rm ~/Library/LaunchAgents/nl.sonobe.spark-transcripts.plist
rm ~/.local/bin/transfer-spark-transcripts.sh
# logs and the per-user manifest can be left or removed as desired
```
