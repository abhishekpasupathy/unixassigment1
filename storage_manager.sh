#!/usr/bin/env bash
# Quota-Aware User Storage Manager — read-only by default.
set -o nounset
set -o pipefail

ROOT="$(cd -- "$(dirname -- "\${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="\${CONFIG_FILE:-$ROOT/config/users.conf}"
REPORT_DIR="\${REPORT_DIR:-$ROOT/reports}"
TOP_N=5
LARGE_FILE_MB=10
OLDER_THAN_DAYS=""
APPLY_MODE=0
REPORT_ONLY=0

usage() {
  cat <<'USAGE'
Usage: ./storage_manager.sh [options]
  -c, --config FILE       Configuration file
  -n, --top N             Number of largest entries/files to show (default 5)
  --large-file-mb N       Cleanup-plan minimum file size in MB (default 10)
  --older-than-days N     Include only cleanup candidates older than N days
  --report-only           Generate reports only; do not offer deletion
  --apply                 Offer per-file deletion confirmation after dry run
  -h, --help              Show help

Exit codes:
  0  All scanned users are OK
  1  At least one user is at WARNING
  2  At least one user has QUOTA EXCEEDED
  3  At least one user was skipped (highest code seen wins)
Default mode is read-only. Even with --apply, type DELETE separately for each file.
USAGE
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

while (($#)); do
  case "$1" in
    -c|--config) (($# >= 2)) || die "Missing config path"; CONFIG_FILE=$2; shift 2 ;;
    -n|--top) (($# >= 2)) || die "Missing top count"; TOP_N=$2; shift 2 ;;
    --large-file-mb) (($# >= 2)) || die "Missing size"; LARGE_FILE_MB=$2; shift 2 ;;
    --older-than-days) (($# >= 2)) || die "Missing age in days"; OLDER_THAN_DAYS=$2; shift 2 ;;
    --report-only) REPORT_ONLY=1; shift ;;
    --apply) APPLY_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "$TOP_N" =~ ^[1-9][0-9]*$ ]] || die "--top must be a positive integer"
[[ "$LARGE_FILE_MB" =~ ^[1-9][0-9]*$ ]] || die "--large-file-mb must be a positive integer"
if [[ -n "$OLDER_THAN_DAYS" && ! "$OLDER_THAN_DAYS" =~ ^[0-9]+$ ]]; then
  die "--older-than-days must be a non-negative integer"
fi
((APPLY_MODE == 0 || REPORT_ONLY == 0)) || die "--apply cannot be combined with --report-only"
[[ "$APPLY_MODE" == 0 ]] || [[ -t 0 ]] || die "--apply needs an interactive terminal"
[[ -r "$CONFIG_FILE" ]] || die "Cannot read $CONFIG_FILE"

for cmd in getent du find sort awk head realpath; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required"
done
mkdir -p -- "$REPORT_DIR" || die "Cannot create report directory"

STAMP="$(date '+%Y%m%d_%H%M%S')"
REPORT="$REPORT_DIR/storage_report_$STAMP.txt"
PLAN="$REPORT_DIR/cleanup_plan_$STAMP.txt"
: > "$REPORT"
: > "$PLAN"

human_size() {
  awk -v kb="$1" 'BEGIN {
    split("KB MB GB TB", units, " ")
    size=kb; i=1
    while (size >= 1024 && i < 4) { size /= 1024; i++ }
    printf "%.2f %s", size, units[i]
  }'
}

valid_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

trim() {
  local value="$1"
  value="\${value#"\${value%%[![:space:]]*}"}"
  value="\${value%"\${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

find_cleanup_candidates() {
  local home="$1" min_bytes="$2"
  local -a age_args=()
  if [[ -n "$OLDER_THAN_DAYS" ]]; then
    age_args=(-mtime "+$OLDER_THAN_DAYS")
  fi
  find "$home" -xdev -type f -size "+$((min_bytes - 1))"c "\${age_args[@]}" \
    -printf '%s\t%p\0' 2>/dev/null | sort -z -nr
}

scan_user() {
  local user="$1" home="$2" quota="$3" warning="$4"
  local entry registered usage_output usage_kb usage_mb pct_x10 pct status du_status
  local dirs rec size path min_bytes count=0

  if ! [[ "$user" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]]; then
    log "WARNING: invalid username '$user'; skipped"
    return 3
  fi

  entry="$(getent passwd "$user" || true)"
  if [[ -z "$entry" ]]; then
    log "WARNING: account $user not found; skipped"
    return 3
  fi

  IFS=: read -r _ _ _ _ _ registered _ <<< "$entry"
  if [[ "$home" != "$registered" ]]; then
    log "WARNING: configured home differs from getent home for $user; skipped"
    return 3
  fi
  if [[ ! -d "$home" || ! -r "$home" || ! -x "$home" ]]; then
    log "WARNING: home missing or unreadable: $home"
    return 3
  fi

  usage_output="$(du -skx -- "$home" 2>/dev/null)"
  du_status=$?
  usage_kb="$(awk 'NR==1 {print $1}' <<< "$usage_output")"
  if ((du_status != 0)); then
    printf 'WARNING: usage may be understated (some paths unreadable)\n'
  fi
  if ! [[ "$usage_kb" =~ ^[0-9]+$ ]]; then
    log "WARNING: cannot calculate usage for $user"
    return 3
  fi

  usage_mb=$((usage_kb / 1024))
  pct_x10=$(( usage_kb * 1000 / (quota * 1024) ))
  pct="$((pct_x10 / 10)).$((pct_x10 % 10))"

  if ((pct_x10 >= 1000)); then
    status="QUOTA EXCEEDED"
  elif ((pct_x10 >= warning * 10)); then
    status="WARNING"
  else
    status="OK"
  fi

  printf '\n============================================================\nUSER: %s\nHOME: %s\nQUOTA: %s MB\n' "$user" "$home" "$quota"
  printf 'Usage: %s (%s MB)\nQuota usage: %s%%\nStatus: %s\n' \
    "$(human_size "$usage_kb")" "$usage_mb" "$pct" "$status"
  printf '%s | %s | %s MB | %s%% | %s\n' \
    "$user" "$home" "$usage_mb" "$pct" "$status" >> "$REPORT"
  [[ "$status" == "OK" ]] || log "$status: $user is at $pct% of quota"

  printf '\nLargest entries:\n'
  dirs="$(du -skx -- "$home"/* "$home"/.[!.]* "$home"/..?* 2>/dev/null |
    sort -nr | head -n "$TOP_N" || true)"
  if [[ -n "$dirs" ]]; then
    while IFS=$'\t' read -r size path; do
      [[ -n "$size" ]] && printf '  %-10s %s\n' "$(human_size "$size")" "$path"
    done <<< "$dirs"
  else
    printf '  No readable entries found.\n'
  fi

  printf '\nLargest files (top %s):\n' "$TOP_N"
  while IFS= read -r -d '' rec; do
    size="\${rec%%$'\t'*}"
    path="\${rec#*$'\t'}"
    if [[ "$size" =~ ^[0-9]+$ ]]; then
      printf '  %-10s %s\n' "$(human_size "$((size / 1024))")" "$path"
    fi
  done < <(
    find "$home" -xdev -type f -printf '%s\t%p\0' 2>/dev/null |
      sort -z -nr | head -z -n "$TOP_N"
  )

  min_bytes=$((LARGE_FILE_MB * 1024 * 1024))
  printf '\nDry-run cleanup candidates (at least %s MB' "$LARGE_FILE_MB"
  if [[ -n "$OLDER_THAN_DAYS" ]]; then
    printf ', older than %s days' "$OLDER_THAN_DAYS"
  fi
  printf '):\n'

  while IFS= read -r -d '' rec; do
    size="\${rec%%$'\t'*}"
    path="\${rec#*$'\t'}"
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    ((count += 1))
    printf '  [PLAN ONLY] %s  %s\n' "$(human_size "$((size / 1024))")" "$path"
    printf '%s\t%s\t%s\n' "$user" "$size" "$path" >> "$PLAN"
  done < <(find_cleanup_candidates "$home" "$min_bytes")
  ((count > 0)) || printf '  No matching files.\n'

  if ((APPLY_MODE == 1 && REPORT_ONLY == 0 && count > 0)); then
    printf 'Interactive cleanup: deletion is permanent; review every path.\n'
    while IFS= read -r -d '' rec; do
      local canonical_home canonical_target answer
      size="\${rec%%$'\t'*}"
      path="\${rec#*$'\t'}"
      canonical_home="$(cd -- "$home" && pwd -P)" || continue
      [[ -f "$path" && ! -L "$path" ]] || { log "Skipping symlink/non-file: $path"; continue; }
      canonical_target="$(realpath -- "$path" 2>/dev/null)" || continue
      case "$canonical_target" in
        "$canonical_home"/*) ;;
        *) log "Rejected path outside home: $path"; continue ;;
      esac

      printf '\nCandidate: %q (%s)\n' "$path" "$(human_size "$((size / 1024))")"
      printf 'Type DELETE to remove this one file; anything else skips: '
      IFS= read -r answer < /dev/tty || answer=''

      if [[ "$answer" == "DELETE" ]]; then
        if rm -- "$canonical_target"; then
          log "Deleted after confirmation: $canonical_target"
          printf 'DELETED | %s | %s\n' "$user" "$canonical_target" >> "$REPORT"
        else
          log "Deletion failed: $canonical_target"
        fi
      else
        printf 'Skipped.\n'
      fi
    done < <(find_cleanup_candidates "$home" "$min_bytes")
  fi

  case "$status" in
    "QUOTA EXCEEDED") return 2 ;;
    WARNING) return 1 ;;
    *) return 0 ;;
  esac
}

printf 'Quota-Aware User Storage Manager\nGenerated: %s\nConfiguration: %s\n' \
  "$(date)" "$CONFIG_FILE" | tee "$REPORT"
if ((APPLY_MODE == 1)); then
  printf 'Mode: interactive per-file confirmation\n' | tee -a "$REPORT"
else
  printf 'Mode: read-only dry run\n' | tee -a "$REPORT"
fi

exit_status=0
line_no=0

while IFS='|' read -r user home quota warning extra || [[ -n "\${user:-}" ]]; do
  ((line_no += 1))
  user="$(trim "$user")"
  home="$(trim "$home")"
  quota="$(trim "$quota")"
  warning="$(trim "$warning")"
  [[ -z "$user" || "$user" == \#* ]] && continue

  if [[ -n "\${extra:-}" || "$home" != /* ]] ||
    ! valid_uint "$quota" || ! valid_uint "$warning"; then
    log "Invalid configuration at line $line_no; expected username|absolute_home|quota_MB|warning_percent (positive integers without leading zeros)" | tee -a "$REPORT"
    continue
  fi

  if ((quota <= 0 || warning <= 0 || warning >= 100)); then
    log "Invalid quota/threshold at line $line_no" | tee -a "$REPORT"
    continue
  fi

  if ! [[ "$user" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]]; then
    log "Invalid username at line $line_no; expected ^[A-Za-z_][A-Za-z0-9._-]*$" | tee -a "$REPORT"
    continue
  fi

  scan_user "$user" "$home" "$quota" "$warning" | tee -a "$REPORT"
  scan_status=\${PIPESTATUS[0]}
  if ((scan_status > exit_status)); then
    exit_status=$scan_status
  fi
done < "$CONFIG_FILE"

printf '\nReports generated:\n  %s\n  %s\n' "$REPORT" "$PLAN" | tee -a "$REPORT"
printf 'No file is deleted unless --apply is used and DELETE is typed for that individual file.\n' |
  tee -a "$REPORT"

exit "$exit_status"
