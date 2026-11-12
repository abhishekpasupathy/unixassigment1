# Quota-Aware User Storage Manager

A Linux Bash project that monitors configured user home directories against storage quotas, identifies major storage consumers, creates warning reports, and prepares a safe cleanup plan.

**Safety:** read-only by default. It never automatically deletes files. Even with `--apply`, each file requires typing `DELETE` separately.

## Features
- Reads configured users, home directories, quotas, and warning thresholds.
- Verifies accounts and registered home directories using `getent passwd`.
- Calculates usage using `du` and finds large files using `find`.
- Ranks storage consumers using `sort` and uses `awk` for formatting.
- Uses Bash loops, functions, input validation, and threshold comparisons.
- Displays OK, WARNING, or QUOTA EXCEEDED using one decimal place of quota usage.
- Generates timestamped usage reports and dry-run cleanup plans.
- Supports an optional age filter for cleanup candidates with `--older-than-days N`.
- Requires individual confirmation before every deletion.

## Structure
```text
unixassigment1/
├── storage_manager.sh
├── config/users.conf
├── reports/
└── README.md
```

## Requirements
Linux (Ubuntu/Debian/Fedora), Bash, GNU findutils/coreutils, and `getent`, `du`, `find`, `sort`, `awk`, `head`, and `realpath`. No third-party packages are required on a typical Linux system.

## Configuration
Edit `config/users.conf`. Each non-comment line uses:
```text
username|absolute_home_directory|quota_in_MB|warning_threshold_percent
alice|/home/alice|2048|80
bob|/home/bob|1024|75
```
Use real accounts. Check the registered home with `getent passwd alice`. Configured home must match the account database exactly. Quota and warning values must be positive integers without leading zeros (for example, use `8`, not `08`). Warning threshold must be 1–99. Usernames must match `^[A-Za-z_][A-Za-z0-9._-]*$`.

## Installation
```bash
git clone https://github.com/abhishekpasupathy/unixassigment1.git
cd unixassigment1
chmod +x storage_manager.sh
```
Edit `config/users.conf` and add a valid local user.

## Running
Default safe scan and dry run:
```bash
./storage_manager.sh
```
Other options:
```bash
./storage_manager.sh --top 10
./storage_manager.sh --large-file-mb 25
./storage_manager.sh --older-than-days 7
./storage_manager.sh --config ./config/users.conf
./storage_manager.sh --report-only
```

`--older-than-days N` adds `-mtime +N` to cleanup candidate discovery. For example, `--older-than-days 7` selects files whose modification time is more than seven 24-hour periods ago. This filter applies to the cleanup plan and interactive candidate list.

Interactive cleanup:
```bash
./storage_manager.sh --apply
```
For each candidate, type exactly `DELETE` to remove only that file. Any other input skips it. The prompt escapes unusual filename characters (including newlines) for safe display, while the program retains the actual path for the deletion operation. Deletion is permanent; inspect every path before confirming. `--apply` requires an interactive terminal and cannot be combined with `--report-only`. Do not run with elevated privileges merely to bypass permissions.

## Reports
Each run creates two timestamped files in `reports/`:
- `storage_report_YYYYMMDD_HHMMSS.txt` — scan output, usage, status, warnings, and deletion outcomes.
- `cleanup_plan_YYYYMMDD_HHMMSS.txt` — proposed files, user names, and byte sizes.

The scan output is appended to the usage report. If `du` exits unsuccessfully, the report warns that usage may be understated because some paths were unreadable.

## Algorithm
1. Parse options and validate configuration.
2. Read user records with a Bash loop.
3. Trim fields and validate usernames, quota, and warning values.
4. Verify the account using `getent passwd`.
5. Match configured home with the account database.
6. Calculate usage with `du -skx`.
7. Calculate quota percentage in tenths using integer arithmetic; display one decimal place without rounding up threshold comparisons.
8. Compare against warning and quota thresholds.
9. List largest entries and regular files.
10. Add large files (and optionally age-filtered files) to the dry-run plan.
11. In `--apply` mode, request exact confirmation separately for every candidate.
12. Save reports and return the highest status code encountered.

## Sample output
```text
USER: alice
HOME: /home/alice
QUOTA: 2048 MB
Usage: 1.25 GB (1280 MB)
Quota usage: 62.5%
Status: OK
Largest files (top 5):
  250.00 MB  /home/alice/Downloads/archive.zip
Dry-run cleanup candidates:
  [PLAN ONLY] 250.00 MB /home/alice/Downloads/archive.zip
No file is deleted unless --apply is used and DELETE is typed for that individual file.
```

## Exit codes
The script returns the highest code encountered while scanning configured users:
| Code | Meaning |
|---:|---|
| 0 | All scanned users are OK |
| 1 | At least one user is at WARNING |
| 2 | At least one user has QUOTA EXCEEDED |
| 3 | At least one user was skipped (account not found, home mismatch, or home missing/unreadable) |

A skipped user takes precedence over quota-exceeded and warning statuses because 3 is the highest code.

## Commands and concepts
| Command/concept | Purpose |
|---|---|
| `du` | Calculates storage usage |
| `find` | Locates regular files and large-file candidates |
| `sort` | Ranks usage in descending order |
| `awk` | Formats sizes and report values |
| `getent` | Verifies users and home directories |
| `mkdir` | Creates report directory |
| `rm` | Removes one file after confirmation |
| Bash loops/functions | Read records and organize the program |

## Validation and safety
- Missing/unreadable config causes a clear error.
- Quota and warning values must be positive integers without leading zeros.
- Warning threshold must be 1–99.
- Invalid usernames and malformed configuration lines are rejected.
- Nonexistent accounts and missing/unreadable homes are skipped with warnings and contribute exit code 3.
- Configured home paths must match `getent` records.
- Scans stay on the home filesystem using `-xdev`.
- Cleanup candidates are regular files, not directories.
- Symlinks and paths outside the configured home are rejected.
- Every deletion requires separate exact confirmation.
- Default execution is non-destructive.

## Course outcome mapping
| Outcome | Project contribution |
|---|---|
| CO1 | Linux/Unix commands and shell scripting |
| CO2 | File-system operations, filters, and pipelines |
| CO3 | Algorithms, loops, validation, and conditional logic |
| CO5 | Practical system-administration utility |
| PO2 | Analyses storage-usage problems |
| PO3 | Designs quota-monitoring and safe-cleanup solution |
| PO5 | Uses Unix tools to implement the solution |
| SDG 9 | Supports reliable digital infrastructure |
| SDG 12 | Encourages responsible storage use and avoids unnecessary deletion |

## Limitations
- Measures configured home directories; not a replacement for kernel-enforced filesystem quotas.
- Inaccessible files may be omitted; a non-zero `du` result produces an understated-usage warning, but the exact missing paths and their sizes cannot be measured.
- Hard links and filesystem accounting can make apparent usage differ from quota accounting.
- Cleanup candidates are based on size and optional modification age, not importance. The operator decides whether removal is safe.
- The cleanup list is generated twice in `--apply` mode, so it can differ from the plan file if files change in between.
- Uses GNU options such as `find -printf` and `sort -z`, unavailable on some Unix variants.

## Author
**Abhishek Pasupathy**  
Unix Assignment — Quota-Aware User Storage Manager
