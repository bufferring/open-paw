# 📋 Releases

---

## v10.2.0 — *The Intelligence Edition* 🧠
**Released:** 2026-03-21

15 improvements across speed, intelligence, and architecture. Quick Mode now streams in real-time. Agent Mode is smarter, learns from tasks, and recovers from errors.

### ⚡ Speed
- **Real-Time Streaming** — Quick Mode now streams tokens to terminal as they generate via Ollama's streaming API. No more staring at a blank screen.
- **Model Keep-Alive** — All API calls include `keep_alive: 30m`. Model stays loaded between calls — eliminates 5-10s cold-start latency.
- **Safe JSON Payloads** — Quick Mode API payload now built via `jq` instead of string interpolation. Prevents special characters in queries from breaking the request. Also adds `-N` (no-buffer) flag to `curl` for proper real-time streaming.
- **Temperature Tuning** — Quick Mode: `0.3` for factual answers. Agent Mode: `0` for deterministic JSON. Both use `top_p: 0.9`.
- **Right-Sized Token Budgets** — Quick: 512 tokens. Agent: 1024 tokens. Agent gets 2x headroom for complex reasoning.

### 🧠 Intelligence
- **Directory Context** — Agent system prompt now includes `ls -1A` snapshot of CWD (top 30 items). Model knows what files exist before proposing commands.
- **Installed Tools Detection** — Probes for 30+ common tools (`python3`, `docker`, `gcc`, `node`, `npm`, `pip`, etc.) at startup. Model only suggests commands for tools that are actually installed. Rule 9 in system prompt enforces this.
- **Auto-Learn Skills** — On successful task completion, saves `{task, commands, summary}` to `skills.json`. Deduplicates by task. Agent builds memory over time and skills are injected into future prompts.
- **Smart Context Pruning** — Sliding window expanded from 6 to 8 turns. System prompt + original task always preserved. Combined into single `jq` call (was 2 separate calls).
- **Error Recovery** — On 2 consecutive JSON parse failures, trims the last 2 context messages (the observation that likely confused the model) and retries with clean context. Resets failure counter on success.
- **9 Agent Rules** — Added Rule 9: "Only use tools/commands that are installed on the system." Rule 3 updated to enforce single-line commands with `;`/`&&` chaining.

### 🏗️ Architecture
- **`--agent` Flag** — Force agent mode for any query, bypassing verb detection. Inverse of `--quick`.
- **Lazy Git Commits** — Single batch `git commit` at session end instead of per-command. Reduces I/O overhead during multi-step tasks.
- **Reduced jq Subshells** — Context update + pruning combined into single `jq` pipeline (was 2 separate `echo | jq` calls per loop iteration).
- **PWD Context in Quick Mode** — Quick Mode prompt now includes OS, current directory, and shell — answers are contextually relevant.

### 📦 Smart Installer
- **Upgrade Detection** — Installer detects existing installations via `is_installed()` and `OPEN_PAW_VERSION` variable. Shows `v10.1.0 → v10.2.0` transition on upgrade.
- **Config Preservation** — On upgrade, `core.json` (model choice), `skills.json` (learned skills), and `global_skills.json` are never overwritten. Previously, every reinstall reset the model to default and wiped learned skills.
- **Script Backup** — Previous version is backed up to `ai.bak` before overwriting. Allows manual rollback if an upgrade breaks something.
- **Spawned Agent Preservation** — Detects and counts custom agents in `agents/` directory, preserves them during upgrade.
- **Model Picker Skipped on Upgrade** — No longer prompts for model selection when upgrading — preserves existing choice automatically.
- **Version Variable** — `OPEN_PAW_VERSION="X.Y.Z"` on line 2 of `open-paw.sh` enables machine-readable version comparison by the installer.
- **Interactive Menu Updated** — When already installed, menu now shows "Upgrade / Reinstall" as option [1], with version displayed in status line.

### 🐛 Bug Fixes
- **Fixed:** Quick Mode streaming returned "No response from model." — `curl` was missing `-N` (no-buffer) flag, causing buffered output that never reached the `while read` loop. Also, the 30s `QUICK_TIMEOUT` was too short for CPU inference cold-starts; unified back to 90s `API_TIMEOUT` since streaming makes long timeouts transparent to the user.
- **Fixed:** Quick Mode JSON payload broke on special characters in queries — String interpolation replaced with `jq -n` safe payload construction.

---

## v10.1.0 — *The Agentic Fix* 🛠️
**Released:** 2026-03-20

Restores full agentic behavior. Command suggestion and execution now works reliably across all common CLI tasks.

### ✨ Improvements
- **150+ Action Verb Gate** — Expanded from ~40 verbs to 150+ stems and full forms. Covers file ops (`touch`, `mkdir`, `rmdir`), networking (`ping`, `ssh`, `curl`, `netstat`), package managers (`apt`, `dnf`, `pip`, `npm`, `brew`, `snap`), services (`systemctl`, `service`, `crontab`), processes (`ps`, `pgrep`, `pkill`, `htop`, `top`), disks (`lsblk`, `fdisk`, `mkfs`, `dd`), and system admin (`useradd`, `passwd`, `chroot`, `ufw`, `iptables`).
- **Conjugation-Safe Matching** — Replaced `grep -Ew` (exact whole-word) with `grep -Ei` (case-insensitive substring). Verb conjugations like "installing", "running", "executed", "created" now correctly trigger Agent Mode.
- **Mandatory Command Schema** — `command` field added to JSON schema `required` array. Model **must** propose a bash command every turn — can no longer return valid JSON without one.
- **Enforced Agent Prompt** — System prompt rewritten with explicit numbered RULES: always provide a command, never converse, only mark done after execution. Prevents small models from drifting into Q&A behavior inside the agent loop.
- **Sudo Pre-Authentication** — Commands containing `sudo` now trigger `sudo -v` before execution. Password prompt happens cleanly before output capture begins. Prevents the sudo password prompt from bleeding into the subshell, which caused empty output and infinite retry loops.
- **Smart Error Detection** — Observations are auto-annotated when output contains permission errors (`Permission denied`, `Operation not permitted`) or when commands time out (exit code 124). Guides the model to adjust its approach instead of blindly retrying the same failing command.
- **Command Sanitizer** — Model-proposed commands are stripped of literal newlines and collapsed to single-line. Prevents terminal prompt corruption when the model generates multi-line commands (e.g. `jq` with embedded newlines).
- **Duplicate Command Guard** — Detects when the model proposes the exact same command twice in a row. Rejects it with an explicit observation forcing a new approach or `done:true`. Breaks the most common infinite loop pattern.
- **Output Sanitizer** — Command output is stripped of control characters (`\x00`–`\x08`, `\x0E`–`\x1F`) and capped at 50 lines before injection into context. Prevents long or binary output from corrupting the model's JSON generation.
- **Improved System Prompt** — 8 numbered rules now include: single-line commands only, report negative findings (e.g. "not found") as completed tasks, never repeat the same command. Empty search results now say "no matches found" instead of misleading "executed successfully."

### 🐛 Bug Fixes
- **Fixed:** Double `OBSERVATION:` prefix in context messages. Feedback from rejected commands and empty-command pushback was prefixed with `OBSERVATION:` twice (`OBSERVATION: OBSERVATION: ...`), corrupting the model's context window.
- **Fixed:** Sudo commands caused infinite loops. `sudo` password prompt inside `timeout ... bash -c` was invisible to output capture, resulting in `[Executed successfully. No output.]` feedback, causing the model to retry the same command until the loop guard fired.
- **Fixed:** Multi-line commands from model broke terminal display. Commands containing literal `\n` (e.g. `jq` with split expressions) corrupted the `read` prompt, showing garbled output and making approval impossible.
- **Fixed:** Model looped on identical commands. When a command returned empty output, the model would retry the same command endlessly until the loop guard fired at iteration 10.

---

## v10.0.0 — *Enter the Paw* 🐾
**Released:** 2026-03-20

The complete rewrite. Open-Paw is now a dual-mode AI daemon: instant answers for questions, full agent loop for CLI tasks.

### ✨ New Features
- **Dual-Mode Execution** — Auto-detects Q&A vs CLI tasks. Questions route to one-shot `/api/generate` for instant answers. Tasks with action verbs enter the full ReAct agent loop.
- **`--quick` flag** — Force instant mode for any query.
- **Loop Guard** — Hard cap at 10 iterations. No more infinite loops. Ever.
- **Command Guard** — Structural enforcement: the script blocks premature `done:true` if no bash command was actually executed. The model can't just *say* it did something.
- **Token Budget** — `num_predict: 512` caps per-turn VRAM usage.
- **Ollama Health Check** — Fails in <5s with a clear message instead of hanging for 120s.
- **Smart Prompt Injection** — Swarm management rules only load when delegation keywords are detected.
- **Professional Installer** — `curl | bash` one-liner install, just like the pros.
- **SVG Logo** — Hand-crafted vector logo with terminal-themed paw print.

### 🐛 Bug Fixes
- **Fixed:** Corrupted JSON syntax in the curl API call (broken `}` closure from v9 edits).
- **Fixed:** Infinite thought loop when the model returned `done:false` without a command — context never progressed.
- **Fixed:** Agent symlinks created in wrong directory — new agents were un-invokable. Now uses `~/.agent_workspace/bin/`.

---

> **⚠️ Versions 8 and 9 were intermediate development builds that were buggy as heck.** They introduced multi-agent orchestration and the swarm architecture, but shipped with critical issues: broken JSON payload closures, infinite reasoning loops, symlinks pointing nowhere, and bloated system prompts that confused small models. v10 is the first stable release of the swarm-era architecture.

---

## v7.0.0 — *The Workspace Update*
**Released:** 2026-02-15

- **Added:** `~/.agent_workspace/` centralized workspace bootstrap.
- **Added:** `core.json` identity registry and `skills.json` structured memory.
- **Added:** `scripts/` sandbox directory for AI-generated bash files.
- **Added:** Self-renaming, model hot-swapping, and cronjob namespacing.

## v6.0.0 — *The Enterprise Update*
**Released:** 2026-02-01

- **Added:** Deterministic JSON execution via Ollama `format: object` schema.
- **Added:** Immutable JSON audit logging (`audit.log`).
- **Added:** Context window pruning (sliding window, last 6 turns).
- **Added:** Execution timeouts (`timeout 60`) and human-in-the-loop (`Y/n/e`).

## v5.0.0 — *The JSON Update*
**Released:** 2026-01-20

- **Added:** Abandoned string parsing. All outputs now enforced via JSON schema.
- **Added:** Session recovery via `/tmp/` and `--resume` flag.
- **Added:** Background audit logging.

## v4.0.0 — *The Visual Update*
**Released:** 2026-01-10

- **Added:** Visual reasoning tunnel with ANSI formatting.
- **Added:** `awk` pipeline for real-time stream interception.
- **Added:** Memory verification via `grep` before skill appending.

## v3.0.0 — *The Telemetry Update*
**Released:** 2025-12-28

- **Added:** Dynamic OS polling (RAM, time, PWD) — removed hardcoded data.
- **Added:** Real-time token streaming via `jq --unbuffered` and `tee`.
- **Added:** Upgraded execution from `eval` to `bash -c`.

## v2.0.0 — *The Loop Update*
**Released:** 2025-12-15

- **Added:** ReAct (Reasoning and Acting) execution loop.
- **Added:** `THOUGHT:` / `COMMAND:` / `DONE:` text parsing.
- **Added:** Observation feedback into the LLM context array.

## v1.0.0 — *Initial Concept*
**Released:** 2025-12-01

- **Added:** Zero-shot bash wrapper around `ollama run`.
- **Added:** Basic `Y/N` confirmation and `eval` execution.