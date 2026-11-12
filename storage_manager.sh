#!/usr/bin/env bash
# Quota-Aware User Storage Manager — read-only by default.
set -o nounset
set -o pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/config/users.conf}"
REPORT_DIR="${REPORT_DIR:-$ROOT/reports}"
TOP_N=5
LARGE_FILE_MB=10
APPLY_MODE=0
REPORT_ONLY=0

usage() {
  cat <<'EOF'
Usage: ./storage_manager.sh [options]
  -c, --config FILE   Configuration file
  -n, --top N         Number of largest files/directories (default 5)
  --large-file-mb N   Cleanup-plan minimum file size in MB (default 10)
  --report-only       Generate reports only
  --apply             Offer per-file deletion confirmation after dry run
  -h, --help          Show help
Default mode is read-only. Even with --apply, type DELETE for each file.
EOF
}
die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

while (($#)); do
  case "$1" in
    -c|--config) (($#>=2)) || die "Missing config path"; CONFIG_FILE=$2; shift 2 ;;
    -n|--top) (($#>=2)) || die "Missing top count"; TOP_N=$2; shift 2 ;;
    --large-file-mb) (($#>=2)) || die "Missing size"; LARGE_FILE_MB=$2; shift 2 ;;
    --report-only) REPORT_ONLY=1; shift ;;
    --apply) APPLY_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ "$TOP_N" =~ ^[1-9][0-9]*$ ]] || die "--top must be positive"
[[ "$LARGE_FILE_MB" =~ ^[0-9]+$ ]] || die "--large-file-mb must be non-negative"
[[ -r "$CONFIG_FILE" ]] || die "Cannot read $CONFIG_FILE"
for cmd in getent du find sort awk head realpath; do command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required"; done
mkdir -p -- "$REPORT_DIR" || die "Cannot create report directory"
STAMP="$(date '+%Y%m%d_%H%M%S')"
REPORT="$REPORT_DIR/storage_report_$STAMP.txt"
PLAN="$REPORT_DIR/cleanup_plan_$STAMP.txt"
: > "$REPORT"; : > "$PLAN"

human_size(){ awk -v kb="$1" 'BEGIN{split("KB MB GB TB",u," ");s=kb;i=1;while(s>=1024&&i<4){s/=1024;i++}printf "%.2f %s",s,u[i]}'; }
valid_uint(){ [[ "$1" =~ ^[0-9]+$ ]]; }

scan_user(){
  local user="$1" home="$2" quota="$3" warning="$4"
  local entry uid registered usage_kb usage_mb pct status
  entry="$(getent passwd "$user" || true)"
  if [[ -z "$entry" ]]; then log "WARNING: account $user not found; skipped"; return; fi
  IFS=: read -r _ _ uid _ _ registered _ <<< "$entry"
  if [[ "$home" != "$registered" ]]; then log "WARNING: configured home differs from getent home for $user; skipped"; return; fi
  if [[ ! -d "$home" || ! -r "$home" || ! -x "$home" ]]; then log "WARNING: home missing or unreadable: $home"; return; fi
  usage_kb="$(du -skx -- "$home" 2>/dev/null | awk 'NR==1{print $1}')"
  [[ "$usage_kb" =~ ^[0-9]+$ ]] || { log "WARNING: cannot calculate usage for $user"; return; }
  usage_mb=$((usage_kb/1024)); pct=$((usage_mb*100/quota))
  if ((pct>=100)); then status="QUOTA EXCEEDED"; elif ((pct>=warning)); then status="WARNING"; else status="OK"; fi

  printf '\n============================================================\nUSER: %s\nHOME: %s\nQUOTA: %s MB\n' "$user" "$home" "$quota"
  printf 'Usage: %s (%s MB)\nQuota usage: %s%%\nStatus: %s\n' "$(human_size "$usage_kb")" "$usage_mb" "$pct" "$status"
  printf '%s | %s | %s MB | %s%% | %s\n' "$user" "$home" "$usage_mb" "$pct" "$status" >> "$REPORT"
  [[ "$status" == "OK" ]] || log "$status: $user is at $pct% of quota"

  printf '\nLargest immediate subdirectories:\n'
  local dirs
  dirs="$(du -skx -- "$home"/* "$home"/.[!.]* "$home"/..?* 2>/dev/null | sort -nr | head -n "$TOP_N" || true)"
  if [[ -n "$dirs" ]]; then
    while IFS=$'\t' read -r size path; do [[ -n "$size" ]] && printf '  %-10s %s\n' "$(human_size "$size")" "$path"; done <<< "$dirs"
  else echo "  No readable subdirectories found."; fi

  printf '\nLargest files (top %s):\n' "$TOP_N"
  while IFS= read -r -d '' rec; do
    local size path
    size="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
    [[ "$size" =~ ^[0-9]+$ ]] && printf '  %-10s %s\n' "$(human_size "$((size/1024))")" "$path"
  done < <(find "$home" -xdev -type f -printf '%s\t%p\0' 2>/dev/null | sort -z -nr | head -z -n "$TOP_N")

  local min_bytes=$((LARGE_FILE_MB*1024*1024)) count=0
  printf '\nDry-run cleanup candidates (at least %s MB):\n' "$LARGE_FILE_MB"
  while IFS= read -r -d '' rec; do
    local size path
    size="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    ((count+=1))
    printf '  [PLAN ONLY] %s  %s\n' "$(human_size "$((size/1024))")" "$path"
    printf '%s\t%s\t%s\n' "$user" "$size" "$path" >> "$PLAN"
  done < <(find "$home" -xdev -type f -size +"$((min_bytes-1))"c -printf '%s\t%p\0' 2>/dev/null | sort -z -nr)
  ((count>0)) || echo "  No matching files."

  if ((APPLY_MODE==1 && REPORT_ONLY==0 && count>0)); then
    echo "Interactive cleanup: deletion is permanent; review every path."
    while IFS= read -r -d '' rec; do
      local size path answer canonical_home canonical_target
      size="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
      canonical_home="$(cd -- "$home" && pwd -P)" || continue
      [[ -f "$path" && ! -L "$path" ]] || { log "Skipping symlink/non-file: $path"; continue; }
      canonical_target="$(realpath -- "$path" 2>/dev/null)" || continue
      case "$canonical_target" in "$canonical_home"/*) ;; *) log "Rejected path outside home: $path"; continue ;; esac
      printf '\nCandidate: %s (%s)\nType DELETE to remove this one file; anything else skips: ' "$path" "$(human_size "$((size/1024))")"
      IFS= read -r answer || answer=""
      if [[ "$answer" == "DELETE" ]]; then
        if rm -- "$canonical_target"; then log "Deleted after confirmation: $canonical_target"; printf 'DELETED | %s | %s\n' "$user" "$canonical_target" >> "$REPORT"
        else log "Deletion failed: $canonical_target"; fi
      else echo "Skipped."; fi
    done < <(find "$home" -xdev -type f -size +"$((min_bytes-1))"c -printf '%s\t%p\0' 2>/dev/null | sort -z -nr)
  fi
}

printf 'Quota-Aware User Storage Manager\nGenerated: %s\nConfiguration: %s\n' "$(date)" "$CONFIG_FILE" | tee "$REPORT"
if ((APPLY_MODE && !REPORT_ONLY)); then echo "Mode: interactive per-file confirmation" | tee -a "$REPORT"; else echo "Mode: read-only dry run" | tee -a "$REPORT"; fi

line_no=0
while IFS='|' read -r user home quota warning extra || [[ -n "${user:-}" ]]; do
  ((line_no+=1))
  user="$(printf '%s' "$user" | tr -d '[:space:]')"
  quota="$(printf '%s' "$quota" | tr -d '[:space:]')"
  warning="$(printf '%s' "$warning" | tr -d '[:space:]')"
  [[ -z "$user" || "$user" == \#* ]] && continue
  if [[ -n "${extra:-}" || "$home" != /* ]] || ! valid_uint "$quota" || ! valid_uint "$warning"; then
    log "Invalid configuration at line $line_no; expected username|absolute_home|quota_MB|warning_percent"; continue
  fi
  if ((quota<=0 || warning<=0 || warning>=100)); then log "Invalid quota/threshold at line $line_no"; continue; fi
  scan_user "$user" "$home" "$quota" "$warning"
done < "$CONFIG_FILE"

printf '\nReports generated:\n  %s\n  %s\n' "$REPORT" "$PLAN"
echo "No file is deleted unless --apply is used and DELETE is typed for that individual file."
