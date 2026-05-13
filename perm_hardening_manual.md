# Operator's Manual
## `perm_hardening_aix.ksh` — Permission Hardening Suite for AIX
### Version 2.0.0

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites & Deployment](#2-prerequisites--deployment)
3. [How to Launch](#3-how-to-launch)
4. [Main Menu](#4-main-menu)
5. [Mode 1 — Discovery](#5-mode-1--discovery)
6. [Mode 2 — Remediation](#6-mode-2--remediation)
7. [Mode 3 — Rollback](#7-mode-3--rollback)
8. [Mode 4 — Verify](#8-mode-4--verify)
9. [Mode 5 — Reports](#9-mode-5--reports)
10. [Mode 6 — Settings](#10-mode-6--settings)
11. [Batch / Non-Interactive Mode](#11-batch--non-interactive-mode)
12. [Output Files Reference](#12-output-files-reference)
13. [Risk Classification Logic](#13-risk-classification-logic)
14. [Remediation Hints Logic](#14-remediation-hints-logic)
15. [End-to-End Worked Example](#15-end-to-end-worked-example)
16. [Quick Reference Card](#16-quick-reference-card)

---

## 1. Overview

`perm_hardening_aix.ksh` is a **single self-contained ksh script** that provides a
complete lifecycle for discovering and remediating insecure file/directory
permissions on AIX systems.

### What it does

| Phase | What happens |
|-------|-------------|
| **Discovery** | Scans one or more paths. Finds world-writable or exact-0777 objects. Produces a Discovery CSV and a Hints CSV with risk classification and suggested remediation. |
| **Remediation** | Reads the Discovery CSV. Captures full pre-state (mode, owner, group, ACL). Runs a mandatory dry-run. On confirmation, applies `chmod`/`chown`/`chgrp`. Generates a rollback script. |
| **Rollback** | Restores every touched object to its exact pre-remediation state — mode, owner, group, and ACL. Supports full or prefix-filtered rollback. |
| **Verify** | Reads the touched CSV from a remediation run. Compares intended post-state against actual current state. Produces a PASS/FAIL report per object. |
| **Reports** | Browse summaries, CSV previews, and risk breakdowns from any past run — all from inside the menu. |
| **Settings** | Persist your site defaults (base output dir, thresholds, scan mode) to `~/.perm_hardening_aix.conf` so they load automatically on every run. |

### Key safety principles

- **Read-only discovery** — the scanner never modifies anything.
- **Mandatory dry-run gate** — remediation always shows you the plan before asking to apply.
- **Explicit YES confirmation** — applying changes requires typing the word `YES` (not just `y`).
- **Symlinks are never touched** — `chmod`/`chown`/`chgrp` are never called on symlinks.
- **Full pre-state capture** — mode, owner, group and ACL (via `aclget`) saved before every change.
- **Atomic rollback script** — generated per-remediation-run; self-contained ksh; supports `-n` dry-run.

---

## 2. Prerequisites & Deployment

### System requirements

| Item | Requirement |
|------|-------------|
| OS | AIX 6.1 or later |
| Shell | ksh88 or ksh93 (`/usr/bin/ksh`) |
| User | root (for remediation/rollback/verify); any user for discovery |
| `perl` | Strongly recommended — enables precise octal stat. Without it, exact `777`/`777D` matching is unreliable. |
| `aclget` / `aclput` | Optional — enables ACL pre-state backup and restore. Present on most AIX systems. |
| `df`, `du`, `find`, `ls`, `awk`, `sed` | Standard AIX utilities — always present. |

### Deployment steps

```sh
# 1. Copy script to AIX host
scp perm_hardening_aix.ksh root@aix-host:/opt/tools/

# 2. Set permissions (owner root, no world access)
chown root:system /opt/tools/perm_hardening_aix.ksh
chmod 700 /opt/tools/perm_hardening_aix.ksh

# 3. Create the output base directory
mkdir -p /mnt/nim_perm_hardening
chown root:system /mnt/nim_perm_hardening
chmod 700 /mnt/nim_perm_hardening

# 4. Verify ksh
whence ksh        # should return /usr/bin/ksh

# 5. Verify perl (recommended)
whence perl       # /usr/bin/perl
```

---

## 3. How to Launch

### Interactive menu (default)
```sh
ksh /opt/tools/perm_hardening_aix.ksh
```
No arguments = full menu-driven interface. This is the normal operator mode.

### Batch / cron (non-interactive)
```sh
ksh /opt/tools/perm_hardening_aix.ksh --discover -r "/download /cdirect"
ksh /opt/tools/perm_hardening_aix.ksh --help
```
See [Section 11](#11-batch--non-interactive-mode) for full batch reference.

---

## 4. Main Menu

When launched interactively you are presented with:

```
============================================================
 Permission Hardening Suite — AIX  v2.0.0
 Host: myaix01   Base: /mnt/nim_perm_hardening
============================================================
  1) Discovery    — scan for insecure permissions
  2) Remediation  — dry-run then apply fixes
  3) Rollback     — restore previous permissions
  4) Verify       — confirm remediation success
  5) Reports      — view summaries / CSVs
  6) Settings     — configure defaults
  0) Exit
============================================================
Select:
```

- The **Host** and **Base output directory** are shown at the top so you always know where output will land.
- Enter the number and press ENTER.
- At any sub-prompt, entering `0` cancels back to the menu without making any changes.

---

## 5. Mode 1 — Discovery

**Purpose:** Scan one or more filesystem paths and produce a full inventory of
world-writable or 0777-permissioned objects, classified by risk level, with
suggested remediation actions.

### Step-by-step walkthrough

#### Step 1 — Enter scan roots

```
Enter one or more paths to scan (space-separated).
Examples: /tmp   /download   /cdirect   /download /cdirect /badata
Scan roots:
```

- Type one or more absolute paths separated by spaces, for example:
  `/download /cdirect /badata`
- If you saved a default in Settings it is shown in brackets — press ENTER to
  accept it, or type new paths to override.
- If a path does not exist on this host, a warning is shown and you are asked
  whether to continue — giving you the chance to correct a typo before wasting
  scan time.
- **You cannot proceed without entering at least one path.** The prompt loops
  until a value is provided.

#### Step 2 — Select permission mode

```
Permission mode:
  1) WW   — world-writable (includes 666/777/1777)
  2) 777  — exact 0777 only
  3) 777D — exact 0777 + 1777 directories
Choice [default: WW]:
```

| Mode | What is matched | When to use |
|------|----------------|-------------|
| `WW` | Any object where the **others-write bit** (`002`) is set — covers 0622, 0666, 0777, 01777, etc. | General hardening scan. Catches the broadest set of insecure permissions. |
| `777` | Objects whose mode is **exactly 0777** (full rwx for all). | Targeted sweep for the most permissive setting only. |
| `777D` | Files that are exactly 0777; directories that are 0777 **or** 01777 (sticky world-writable). | When you want to flag sticky dirs alongside fully-open files. |

#### Step 3 — Select candidate enumeration strategy

```
Candidate enumeration:
  1) AUTO — auto-detect (recommended)
  2) STAT — enumerate all, filter via stat
  3) FIND — use find -perm -002 (fast; AIX find must support it)
Choice [default: AUTO]:
```

| Option | How it works | When to choose |
|--------|-------------|---------------|
| `AUTO` | Probes whether AIX `find -perm -002` works correctly; uses it if it does, falls back to STAT otherwise. | **Always use this unless you have a specific reason.** |
| `STAT` | Enumerates every non-symlink object with `find`, then calls `perl stat` or `ls` on each to check the mode. Slower but 100% compatible with every AIX version. | If AUTO gives unexpected results or on very old AIX. |
| `FIND` | Forces use of `find -perm -002`. Fast. | Only if you have confirmed AIX `find` supports `-perm` correctly on your version. |

#### Step 4 — /tmp handling (shown only if /tmp is in your roots)

```
Include /tmp itself as a finding? [y/N]:
```

- `/tmp` is normally `1777` (sticky world-writable) on all UNIX systems and is
  **expected** — answering `N` (default) excludes the `/tmp` directory entry
  itself but **still scans everything inside /tmp**.
- Answer `Y` only if you specifically want `/tmp` itself to appear in the
  findings (e.g. for a compliance report that must document it).

#### Step 5 — Output directory

```
Output base dir [default: /mnt/nim_perm_hardening]:
```

Press ENTER to accept the default, or type an alternative path.
A timestamped sub-directory `discovery_YYYYMMDD_HHMM` is always created inside
this base directory — you never overwrite a previous run.

#### Step 6 — Confirmation and scan

```
============================================================
 About to scan:
   Roots:       /download /cdirect
   Perm mode:   WW
   Candidate:   AUTO
   Excl /tmp:   YES
   Output:      /mnt/nim_perm_hardening
============================================================
Proceed with discovery? [y/N]:
```

A summary of all selected options is shown before anything runs.
Type `y` to start the scan. The scanner prints a live summary on completion:

```
==================================================
 Permission Discovery Summary — v2.0.0
==================================================
 Host:           myaix01
 Scan roots:     /download /cdirect
 Perm mode:      WW
 ...
 RESULTS:
   Total matching items:   47
   HIGH risk:              12
   MEDIUM risk:            18
   LOW risk:               17
   Items with ACL (+):      3
 OUTPUT FILES:
   Discovery CSV:  /mnt/nim_perm_hardening/discovery_20250509_1430/discovery_perm_download_20250509_1430.csv
   Hints CSV:      /mnt/nim_perm_hardening/discovery_20250509_1430/hints_perm_download_20250509_1430.csv
   Summary:        /mnt/.../summary_perm_...txt
   Log:            /mnt/.../discover_...log
==================================================
```

### Output files produced

| File | Contents |
|------|----------|
| `discovery_perm_*.csv` | Full inventory: path, type, octal mode, owner, group, mtime, size, parent, recursive count, ACL flag, mount point. |
| `hints_perm_*.csv` | Risk level, justification, current mode, suggested mode/owner/group, notes per object. |
| `summary_perm_*.txt` | Human-readable summary of counts and file locations. |
| `discover_*.log` | Timestamped execution log with candidate counts and debug detail. |
| `run.meta` | Machine-readable key=value metadata used by the menu to display run details. |

---

## 6. Mode 2 — Remediation

**Purpose:** Apply permission fixes to objects found during discovery.
Always dry-runs first. Captures full pre-state. Generates a rollback script.

### Step-by-step walkthrough

#### Step 1 — Select a discovery run (version)

```
============================================================
Select a discovery run (version)
------------------------------------------------------------
[1] discovery_20250509_1430   mode=WW   items=47   high=12   2025-05-09 14:30:00
[2] discovery_20250508_0200   mode=WW   items=39   high= 9   2025-05-08 02:00:00
Enter number (0 to cancel):
```

All past discovery runs under your base directory are listed with their
metadata — mode, total items found, HIGH count, and creation timestamp.
This versioning means you can always tie a remediation back to the exact
scan it came from.

#### Step 2 — Select the discovery CSV

If the run contains more than one discovery CSV (e.g. from a multi-root scan
that was relabelled), you are shown a numbered list to pick from.

#### Step 3 — Use hints CSV?

```
Use hints CSV for suggested modes / risk filter? [y/N]:
```

Answering `Y` unlocks two capabilities:
- **Suggested modes** — the hints CSV contains per-object recommended `chmod`
  values derived from path patterns (scripts → 0750, config → 0640, etc.).
- **Risk-level filtering** — you can remediate only HIGH-risk items in one
  pass, then MEDIUM in a second pass, etc.

#### Step 4 — Remediation scope

```
Remediation scope:
  1) All items in CSV
  2) Prefix / directory
  3) Single specific path
  4) Risk level filter (requires hints CSV)
Choice:
```

| Option | What it does | Example use |
|--------|-------------|-------------|
| `1` All items | Every row in the CSV is processed. | Full remediation of a scan. |
| `2` Prefix | Only objects whose path starts with the given prefix. | Fix one application directory without touching others. |
| `3` Single path | Exactly one specific path. | Targeted fix of a single file or directory. |
| `4` Risk level | Only objects at a given risk level (LOW / MEDIUM / HIGH / ALL). | Prioritised remediation — fix HIGH first, review MEDIUM separately. |

For options 2 and 3 you are prompted:
```
Enter directory prefix (e.g. /tmp/mydir):
```
```
Enter full path:
```

For option 4:
```
Risk level (LOW|MEDIUM|HIGH|ALL):
```

#### Step 5 — Target mode/owner/group source

```
Target mode/owner/group source:
  1) Use hints suggestions (requires hints CSV)
  2) Override mode only
  3) Override mode + owner + group
Choice:
```

| Option | What it does |
|--------|-------------|
| `1` Hints | Uses the `SUGGESTED_MODE`, `SUGGESTED_OWNER`, `SUGGESTED_GROUP` columns from the hints CSV. Each object gets an individually appropriate mode based on its path and type. |
| `2` Override mode | You type one octal mode (e.g. `0750`) that is applied uniformly to all scoped objects. Owner and group are left unchanged. |
| `3` Override all | You type mode, owner, and group. Enter `-` for owner or group to leave it unchanged. |

**Examples for option 3 input:**
```
Mode:              2770
Owner (- to keep): cdirect
Group (- to keep): cdirect
```
```
Mode:              0640
Owner (- to keep): -
Group (- to keep): -
```

#### Step 6 — Mandatory dry-run

The dry-run **always runs first** — this is not optional.

```
============================================================
 DRY-RUN MODE — no changes will be made
============================================================
[PLAN] /download/scripts/deploy.sh  0777->0750  root:system -> -:-
[PLAN] /download/in                 0777->1770  cdirect:cdirect -> cdirect:cdirect
[PLAN] /cdirect/data/export.csv     0666->0660  app1:staff -> -:-
...
DRY-RUN COMPLETE
  Planned:  14
  Applied:  0
  Skipped:  33
  Failed:   0
```

Review the `[PLAN]` lines carefully:
- Format: `path  current_mode -> new_mode  current_owner:group -> new_owner:group`
- `Skipped` means the object was already at the target state — no change needed.

#### Step 7 — Apply confirmation

```
Dry-run complete. Review plan above.
Apply changes now? [y/N]:
```

If you answer `Y`, a second confirmation with the full `YES` requirement follows:

```
============================================================
Type YES to proceed:
```

You must type the **word YES** exactly. Any other input aborts safely.

#### Step 8 — Apply and results

```
APPLY COMPLETE
  Planned:  14
  Applied:  14
  Skipped:  33
  Failed:   0
  Log:      /mnt/nim_perm_hardening/discovery_.../remediation_.../remediate_...log
  Touched:  /mnt/.../remediate_touched_...csv
  Rollback: /mnt/.../rollback_permissions_...sh
  ACL bkp:  /mnt/.../acl_backup_.../
  Verify:   ksh perm_hardening_aix.ksh (select Verify from menu)
```

If any item fails (e.g. a locked file), it is shown in red and counted under
`Failed`. The rollback script is still generated for all successfully applied items.

### Output files produced

| File | Contents |
|------|----------|
| `remediate_*.log` | Full timestamped log of every action taken or skipped. |
| `remediate_touched_*.csv` | Pre- and post-state for every object that was planned: old mode/owner/group/ACL file path, new mode/owner/group, result (OK / FAIL_CHMOD / FAIL_CHOWN / DRYRUN). |
| `rollback_permissions_*.sh` | Self-contained ksh script. Running it restores every touched object to its exact pre-remediation state. Supports `-n` for dry-run. |
| `acl_backup_*/` | Directory containing one `.acl` file per object that had an ACL (`+` marker in `ls -l`). Restored by `aclput` during rollback. |

---

## 7. Mode 3 — Rollback

**Purpose:** Restore objects to their exact pre-remediation state — mode,
owner, group, and ACL.

### Step-by-step walkthrough

#### Step 1 — Select the discovery run

Same versioned run selector as in Remediation. Pick the run that contains the
remediation you want to roll back.

#### Step 2 — Select the rollback script

```
------------------------------------------------------------
[1] /mnt/.../remediation_20250509_143500/rollback_permissions_20250509_143500.sh   (touched=14)
[2] /mnt/.../remediation_20250509_110000/rollback_permissions_20250509_110000.sh   (touched= 8)
Enter number (0 to cancel):
```

The `touched=N` count tells you how many objects this rollback script will
restore, so you can immediately identify which remediation run it belongs to.

#### Step 3 — Rollback scope

```
Rollback scope:
  1) Full rollback (all items in rollback script)
  2) Prefix-filtered rollback (subset by path prefix)
Choice:
```

| Option | When to use |
|--------|------------|
| `1` Full | Undo the entire remediation run — restore all touched objects. |
| `2` Prefix | Undo only objects under a specific directory. Useful when a remediation covered multiple application areas and only one needs to be rolled back. |

For option 2:
```
Enter prefix to rollback (e.g. /tmp/test1):
```

#### Step 4 — Dry-run or real

```
  1) Dry-run
  2) Real rollback
Choice:
```

**Always run dry-run first** when doing a prefix rollback to confirm the right
objects are in scope before making changes.

Dry-run output example:
```
DRYRUN: chmod 0777 '/download/scripts/deploy.sh'
DRYRUN: chown root:system '/download/scripts/deploy.sh'
DRYRUN: chmod 0777 '/download/in'
DRYRUN: chown cdirect:cdirect '/download/in'
```

#### Step 5 — Full rollback confirmation

For a full rollback (scope option 1) the rollback script itself is called
directly and handles its own confirmation logic.
For a prefix rollback (scope option 2) you are shown the scope summary and
asked to confirm before any change is made.

---

## 8. Mode 4 — Verify

**Purpose:** After a remediation, confirm that every object that was changed
is actually at its intended post-state. Produces a PASS/FAIL CSV report.

### Step-by-step walkthrough

#### Step 1 — Select the discovery run
#### Step 2 — Select the remediation directory

```
[1] /mnt/.../remediation_20250509_143500
[2] /mnt/.../remediation_20250509_110000
Select remediation directory (or 0 to cancel):
```

#### Step 3 — Confirm and run

```
Using touched CSV: /mnt/.../remediate_touched_20250509_143500.csv
Run verify? [y/N]:
```

Verify reads the `remediate_touched_*.csv` from the selected remediation
directory. For each object it compares:
- Intended mode vs actual current mode
- Intended owner vs actual current owner
- Intended group vs actual current group

#### Step 4 — Results

```
============================================================
 Verify complete
  PASS:    14
  FAIL:     0
  MISSING:  0
  Report:  /mnt/.../verify_report_20250509_143600.csv
============================================================
All items verified PASS.
```

If failures are found:
```
WARNING: Some items did not match intended state.
Review report: /mnt/.../verify_report_...csv
```

### Verify report CSV columns

| Column | Meaning |
|--------|---------|
| `FULL_PATH` | Object path |
| `INTENDED_MODE` | Mode that was applied during remediation |
| `ACTUAL_MODE` | Mode read back now from the filesystem |
| `INTENDED_OWNER` | Owner that was set (or `-` if unchanged) |
| `ACTUAL_OWNER` | Owner read back now |
| `INTENDED_GROUP` | Group that was set (or `-` if unchanged) |
| `ACTUAL_GROUP` | Group read back now |
| `RESULT` | `PASS` / `FAIL` / `MISSING` |

---

## 9. Mode 5 — Reports

**Purpose:** Browse and review output from any past run without leaving the
menu. No external tools needed.

### Step 1 — Select a discovery run

### Step 2 — Choose report type

```
Report type:
  1) Summary TXT
  2) Discovery CSV (head preview)
  3) Hints CSV (head preview)
  4) Risk breakdown from hints
  5) List remediation sub-directories
  6) Latest verify report
Choice:
```

| Option | What you see |
|--------|-------------|
| `1` Summary TXT | Full discovery summary — host, roots, mode, counts, file paths. |
| `2` Discovery CSV preview | Header + first 25 data rows + total row count. |
| `3` Hints CSV preview | Header + first 25 data rows showing risk, suggested modes, notes. |
| `4` Risk breakdown | Counts of LOW / MEDIUM / HIGH items from the hints CSV — one line per level. |
| `5` Remediation directories | Lists all `remediation_*` sub-directories under the selected run, with their touched-item count. |
| `6` Latest verify report | Prints the most recent `verify_report_*.csv` under the selected run in full. |

---

## 10. Mode 6 — Settings

**Purpose:** Configure and persist site-specific defaults so they load
automatically on every run without re-entering them each time.

Settings are saved to `~/.perm_hardening_aix.conf` (root's home directory).

### Settings menu

```
============================================================
 SETTINGS
============================================================
  BASE_OUT         = /mnt/nim_perm_hardening
  DEFAULT_ROOTS    =
  DEFAULT_MODE     = WW
  DEFAULT_CAND     = AUTO
  RECENT_DAYS      = 90
  LARGE_MB         = 100
  HIGH_FILES       = 1000
  EXCLUDE_TMP_ROOT = 1
  SKIP_ACL         = 0
  Config file      = /root/.perm_hardening_aix.conf
------------------------------------------------------------
  1) Change BASE_OUT
  2) Change DEFAULT_ROOTS (leave blank to always prompt)
  3) Change DEFAULT_MODE (WW|777|777D)
  4) Change DEFAULT_CAND (AUTO|STAT|FIND)
  5) Change RECENT_DAYS
  6) Change LARGE_MB
  7) Change HIGH_FILES
  8) Toggle EXCLUDE_TMP_ROOT (current: 1)
  9) Toggle SKIP_ACL (current: 0)
 10) Save settings to /root/.perm_hardening_aix.conf
  0) Back
```

### Settings reference

| Setting | Default | Description |
|---------|---------|-------------|
| `BASE_OUT` | `/mnt/nim_perm_hardening` | Base directory where all run output is stored. |
| `DEFAULT_ROOTS` | *(empty)* | Pre-fill for the scan roots prompt. Leave empty to always force the operator to type paths explicitly — recommended for safety. Set to e.g. `/download /cdirect` if your environment has fixed scan targets. |
| `DEFAULT_MODE` | `WW` | Default permission mode for discovery. |
| `DEFAULT_CAND` | `AUTO` | Default candidate enumeration strategy. |
| `RECENT_DAYS` | `90` | Objects accessed within this many days are classified MEDIUM risk (unless another HIGH condition applies). |
| `LARGE_MB` | `100` | Directories larger than this (MB) are classified HIGH risk. |
| `HIGH_FILES` | `1000` | Directories containing more than this many recursive items are classified HIGH risk. |
| `EXCLUDE_TMP_ROOT` | `1` (YES) | Whether to exclude `/tmp` itself from findings (its contents are still scanned). Toggle between 0 and 1. |
| `SKIP_ACL` | `0` (NO) | Set to `1` to skip ACL detection (`ls -l` `+` marker check) for faster scans on large filesystems. ACL backup/restore during remediation is also skipped. |

**Important:** Changes take effect immediately in the current session.
Press **10** to write them to the config file so they persist across sessions.

---

## 11. Batch / Non-Interactive Mode

For use in cron jobs, automation pipelines, or scripted workflows.

### General syntax

```sh
ksh perm_hardening_aix.ksh <--verb> [options]
```

### --discover

```sh
ksh perm_hardening_aix.ksh --discover \
    -r "<roots>"       # Required: quoted, space-separated paths
    [-M WW|777|777D]   # Perm mode          (default: from config or WW)
    [-C AUTO|STAT|FIND]# Candidate mode     (default: AUTO)
    [-I]               # Include /tmp itself in findings
    [-o <outbase>]     # Override base output directory
```

**Examples:**
```sh
# Scan /download and /cdirect for world-writable objects
ksh perm_hardening_aix.ksh --discover -r "/download /cdirect"

# Scan /tmp for exact 0777 objects, include /tmp itself
ksh perm_hardening_aix.ksh --discover -r /tmp -M 777 -I

# Scan with custom output location
ksh perm_hardening_aix.ksh --discover -r "/badata /download" -o /var/audit/perms
```

### --remediate

```sh
ksh perm_hardening_aix.ksh --remediate \
    -c <discovery.csv>         # Required
    [-H <hints.csv>]           # Use suggested modes from hints
    [-m <mode>]                # Override mode (e.g. 0750 or 2770)
    [-o <owner>]               # Override owner  (- to keep)
    [-g <group>]               # Override group  (- to keep)
    [-l LOW|MEDIUM|HIGH|ALL]   # Risk filter (requires -H)
    [-d <dir_prefix>]          # Scope to directory prefix
    [-p <exact_path>]          # Scope to one path
    [-O <outdir>]              # Output directory
    [-n]                       # Dry-run only — no apply
```

**Batch safety:** Without `-n`, the script automatically runs a dry-run pass
first (output to `<outdir>_dryrun`) and then applies. The `YES` confirmation
prompt is suppressed in batch mode — the operator's intent to run `--remediate`
without `-n` is treated as the confirmation.

**Examples:**
```sh
# Dry-run only — inspect the plan, no changes
ksh perm_hardening_aix.ksh --remediate \
    -c /mnt/nim_perm_hardening/discovery_20250509_1430/discovery_perm_download_20250509_1430.csv \
    -n

# Apply hints-suggested modes for HIGH-risk items only
ksh perm_hardening_aix.ksh --remediate \
    -c /mnt/.../discovery_perm_download_20250509_1430.csv \
    -H /mnt/.../hints_perm_download_20250509_1430.csv \
    -l HIGH

# Apply a uniform mode to one directory prefix
ksh perm_hardening_aix.ksh --remediate \
    -c /mnt/.../discovery_perm_download_20250509_1430.csv \
    -m 2770 -o cdirect -g cdirect \
    -d /download/in
```

### --rollback

```sh
ksh perm_hardening_aix.ksh --rollback \
    -R <rollback.sh>           # Full rollback script path
    [-n]                       # Dry-run
    [-P <prefix>]              # Prefix-filtered rollback
    [-T <touched.csv>]         # Required when using -P
```

**Examples:**
```sh
# Full rollback — dry-run first
ksh perm_hardening_aix.ksh --rollback \
    -R /mnt/.../remediation_20250509_143500/rollback_permissions_20250509_143500.sh \
    -n

# Full rollback — real
ksh perm_hardening_aix.ksh --rollback \
    -R /mnt/.../rollback_permissions_20250509_143500.sh

# Prefix rollback — restore only /download/in
ksh perm_hardening_aix.ksh --rollback \
    -T /mnt/.../remediate_touched_20250509_143500.csv \
    -P /download/in
```

### --verify

```sh
ksh perm_hardening_aix.ksh --verify \
    -T <touched.csv>           # Required
    [-O <outdir>]              # Output directory for report
```

**Example:**
```sh
ksh perm_hardening_aix.ksh --verify \
    -T /mnt/.../remediation_20250509_143500/remediate_touched_20250509_143500.csv \
    -O /mnt/.../remediation_20250509_143500/
```

### Cron example (nightly scan + auto-fix LOW risk)

```sh
# /etc/cron.d/perm_hardening  (AIX crontab entry)
# Nightly discovery at 02:00
0 2 * * * root ksh /opt/tools/perm_hardening_aix.ksh \
    --discover -r "/download /cdirect" -M WW \
    >> /var/log/perm_hardening_discover.log 2>&1

# Auto-remediate LOW-risk items at 03:00 (adjust CSV path to latest run)
0 3 * * * root ksh /opt/tools/perm_hardening_aix.ksh \
    --remediate \
    -c $(ls -1t /mnt/nim_perm_hardening/discovery_*/discovery_perm_*.csv | head -1) \
    -H $(ls -1t /mnt/nim_perm_hardening/discovery_*/hints_perm_*.csv     | head -1) \
    -l LOW \
    >> /var/log/perm_hardening_remediate.log 2>&1
```

---

## 12. Output Files Reference

All output lands under `BASE_OUT/discovery_YYYYMMDD_HHMM/`.
Remediation output lands in a `remediation_YYYYMMDD_HHMMSS/` sub-directory.

```
/mnt/nim_perm_hardening/
└── discovery_20250509_1430/               ← one per scan run
    ├── run.meta                           ← machine-readable run metadata
    ├── discover_20250509_1430.log         ← scanner execution log
    ├── summary_perm_download_20250509_1430.txt
    ├── discovery_perm_download_20250509_1430.csv
    ├── hints_perm_download_20250509_1430.csv
    └── remediation_20250509_143500/       ← one per remediation run
        ├── remediate_20250509_143500.log
        ├── remediate_touched_20250509_143500.csv
        ├── rollback_permissions_20250509_143500.sh
        ├── acl_backup_20250509_143500/
        │   ├── download_scripts_deploy.sh_20250509_143500.acl
        │   └── ...
        └── verify_report_20250509_143600.csv
```

### Discovery CSV columns

| # | Column | Example |
|---|--------|---------|
| 1 | `FULL_PATH` | `/download/scripts/deploy.sh` |
| 2 | `OBJECT_TYPE` | `file` / `directory` / `symlink` |
| 3 | `CURRENT_PERMISSION` | `0777` |
| 4 | `OWNER` | `root` |
| 5 | `GROUP` | `system` |
| 6 | `LAST_MODIFIED` | `May  9 14:22` |
| 7 | `SIZE_KB` | `12` |
| 8 | `PARENT_DIRECTORY` | `/download/scripts` |
| 9 | `RECURSIVE_ITEM_COUNT` | `1` (files) / N (directories) |
| 10 | `ACL_SET` | `YES` / `NO` / `skipped` |
| 11 | `MOUNT_POINT` | `/download` |

### Hints CSV columns

| # | Column | Example |
|---|--------|---------|
| 1 | `FULL_PATH` | `/download/scripts/deploy.sh` |
| 2 | `OBJECT_TYPE` | `file` |
| 3 | `RISK_LEVEL` | `HIGH` |
| 4 | `RISK_JUSTIFICATION` | `Script directory — integrity risk` |
| 5 | `CURRENT_PERMISSION` | `0777` |
| 6 | `OWNER` | `root` |
| 7 | `GROUP` | `system` |
| 8 | `SIZE_KB` | `12` |
| 9 | `RECURSIVE_ITEM_COUNT` | `1` |
| 10 | `ACL_SET` | `NO` |
| 11 | `SUGGESTED_MODE` | `0750` |
| 12 | `SUGGESTED_OWNER` | `cdirect` |
| 13 | `SUGGESTED_GROUP` | `staff` |
| 14 | `NOTES` | `Shell script: remove world perms (integrity risk).` |

---

## 13. Risk Classification Logic

Risk is assigned per object using the following priority order
(first matching rule wins for HIGH/MEDIUM; LOW is the fallback):

| Priority | Condition | Risk |
|----------|-----------|------|
| 1 | Directory with > `HIGH_FILES` recursive items | HIGH |
| 2 | Directory larger than `LARGE_MB` MB | HIGH |
| 3 | Object accessed within the last **7 days** | HIGH |
| 4 | Known critical path (see table below) | HIGH |
| 5 | ACL present (`+` in `ls -l`) | HIGH |
| 6 | Accessed within `RECENT_DAYS` (default 90) but ≥ 7 days ago | MEDIUM |
| 7 | Everything else | LOW |

### Known critical paths (always HIGH)

| Path pattern | Reason |
|-------------|--------|
| `/download/in`, `/cdirect/in` | Active integration drop zones |
| `/download/out`, `/badata/out` | Active output zones |
| `/download/scripts*`, `/cdirect/scripts*` | Script directories — integrity risk |
| `/download`, `/cdirect` | Mount-point roots — broad impact |

Thresholds (`RECENT_DAYS`, `LARGE_MB`, `HIGH_FILES`) are configurable in Settings.

---

## 14. Remediation Hints Logic

Suggested modes are derived from path pattern and object type:

### Directories

| Path pattern | Suggested mode | Owner | Group | Rationale |
|-------------|---------------|-------|-------|-----------|
| `/tmp` | `1777` | `root` | `system` | Expected sticky world-writable — do not change |
| `/download/in`, `/cdirect/in` | `1770` | `cdirect` | `cdirect` | Drop zone: sticky, group-only write |
| `/download/out`, `/badata/out` | `1770` | `cdirect` | `cdirect` | Output zone: sticky |
| `/download/scripts*`, `/cdirect/scripts*` | `2750` | `cdirect` | `staff` | Remove world; setgid preserves group |
| All others | `2770` | `-` | `-` | Remove world write; confirm group first |

### Files

| Extension | Suggested mode | Rationale |
|-----------|---------------|-----------|
| `.sh` `.ksh` `.bash` | `0750` | Scripts — no world access (integrity) |
| `.cfg` `.conf` `.ini` `.od` `.cd` | `0640` | Config — no world access |
| `.csv` `.txt` `.log` | `0660` | Data/log — group rw, no world |
| *(all others)* | `0640` | Conservative default |

These are **suggestions** — the operator always reviews them in the dry-run
before applying. Override with `-m`/`-o`/`-g` or option 2/3 in the menu if
your application has different requirements.

---

## 15. End-to-End Worked Example

This walks through a complete hardening cycle on `/download` and `/cdirect`.

### Step 1 — Launch the menu

```sh
ksh /opt/tools/perm_hardening_aix.ksh
```

### Step 2 — Run Discovery (menu option 1)

```
Scan roots: /download /cdirect
Permission mode: 1 (WW)
Candidate: 1 (AUTO)
Include /tmp itself: N
Output: (ENTER for default)
Proceed: y
```

Result: `47 items found — HIGH:12  MEDIUM:18  LOW:17`

### Step 3 — Review findings (menu option 5 → option 4)

```
Risk breakdown:
  HIGH      12
  LOW       17
  MEDIUM    18
```

Use option 2 (Discovery CSV preview) to spot-check the highest-risk paths.

### Step 4 — Remediate HIGH risk first (menu option 2)

```
Select run:        [1] discovery_20250509_1430
Select CSV:        [1] discovery_perm_download_20250509_1430.csv
Use hints CSV:     Y → [1] hints_perm_download_20250509_1430.csv
Scope:             4 (Risk level filter)
Risk level:        HIGH
Mode source:       1 (Use hints suggestions)
Dry-run:           Y  → review 12 PLAN lines
Apply:             Y  → type YES
```

Result: `Applied: 12  Skipped: 0  Failed: 0`

### Step 5 — Verify (menu option 4)

```
Select run:              [1] discovery_20250509_1430
Select remediation dir:  [1] remediation_20250509_143500
Run verify:              Y
```

Result: `PASS: 12  FAIL: 0  MISSING: 0`

### Step 6 — Remediate MEDIUM risk

Repeat Step 4 with risk level `MEDIUM`.

### Step 7 — If an application breaks — Rollback

```
Menu option 3 → Rollback
Select run:            [1] discovery_20250509_1430
Select rollback:       [1] rollback_permissions_20250509_143500.sh (touched=12)
Scope:                 2 (Prefix-filtered)
Prefix:                /download/scripts
Dry-run first:         1 → confirm output
Real rollback:         2 → confirm
```

Only `/download/scripts/*` objects are restored. Everything else remains fixed.

---

## 16. Quick Reference Card

```
============================================================
 perm_hardening_aix.ksh v2.0.0 — Quick Reference
============================================================

LAUNCH
  ksh perm_hardening_aix.ksh            Interactive menu
  ksh perm_hardening_aix.ksh --help     Batch usage

MENU
  1 Discovery   2 Remediation   3 Rollback
  4 Verify      5 Reports       6 Settings   0 Exit

DISCOVERY MODES
  WW    = others-write bit set (broadest — use for general scans)
  777   = exact 0777 only
  777D  = exact 0777 files + 0777/1777 directories

CANDIDATE MODES
  AUTO  = probe AIX find; fallback to stat  (always use this)
  STAT  = enumerate all, perl/ls stat check (slowest, most compatible)
  FIND  = force find -perm -002             (fastest, AIX find must support it)

RISK LEVELS
  HIGH   = accessed <7d, or large dir, or critical path, or ACL present
  MEDIUM = accessed <RECENT_DAYS (default 90d) but >=7d
  LOW    = everything else

BATCH VERBS
  --discover   -r <roots> [-M mode] [-C cand] [-I] [-o outbase]
  --remediate  -c <csv> [-H hints] [-m mode] [-o owner] [-g group]
               [-l level] [-d prefix] [-p path] [-O outdir] [-n]
  --rollback   -R <script> [-n] | -T <touched.csv> -P <prefix> [-n]
  --verify     -T <touched.csv> [-O outdir]

OUTPUT LAYOUT
  BASE_OUT/
  └── discovery_YYYYMMDD_HHMM/
      ├── run.meta
      ├── discovery_perm_*.csv
      ├── hints_perm_*.csv
      ├── summary_perm_*.txt
      ├── discover_*.log
      └── remediation_YYYYMMDD_HHMMSS/
          ├── remediate_*.log
          ├── remediate_touched_*.csv
          ├── rollback_permissions_*.sh
          ├── acl_backup_*/
          └── verify_report_*.csv

SAFETY RULES (never bypassed)
  - Discovery is always read-only
  - Dry-run always runs before apply
  - Apply requires typing YES explicitly
  - Symlinks are never chmod/chown'd
============================================================
```
