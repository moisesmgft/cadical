#!/usr/bin/env bash

# Batch runner for CaDiCaL's MAB-enabled build. It enumerates all '.cnf' files
# in a directory (non-recursive), skips those with an existing log, and runs the
# pending instances in parallel through 'run-cadical-mab.sh'.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"

runner=""
for candidate in \
  "$script_dir/run-cadical-mab.sh" \
  "$root_dir/run-cadical-mab.sh" \
  "$root_dir/examples/run-cadical-mab.sh"
do
  if [ -x "$candidate" ]; then
    runner="$candidate"
    break
  fi
done

die() {
  printf 'run-batch-mab: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/run-batch-mab.sh --log-suffix SUFFIX [options] <cnf-dir> [-- cadical-options...]

Options:
  --log-suffix S  Required identifier appended to the log directory name.
  --log-dir DIR   Base directory for logs (default base: <cnf-dir>/logs). The
                  suffix is always appended to ensure unique directories.
  --jobs N        Maximum concurrent runs (default: $JOBS, else 8).
  --time-limit S  Per-instance time limit in seconds (default: 5000; 0 disables).
  -h, --help      Show this help message.

Arguments after '--' are forwarded to 'run-cadical-mab.sh' for every instance.
Each CNF produces '<log-dir>/<instance>.log' after completion; existing logs
are treated as finished runs and skipped. The last line of every log is a
SUMMARY entry stating SAT/UNSAT, TLE, or error along with elapsed time.
EOF
}

cnf_dir=""
log_dir_opt=""
jobs_opt=""
log_suffix=""
time_limit_opt=""
forward_args=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --log-dir)
      [ "$#" -lt 2 ] && die "'--log-dir' expects a path argument"
      log_dir_opt="$2"
      shift 2
      ;;
    --log-dir=*)
      log_dir_opt="${1#*=}"
      shift
      ;;
    --jobs)
      [ "$#" -lt 2 ] && die "'--jobs' expects an integer argument"
      jobs_opt="$2"
      shift 2
      ;;
    --jobs=*)
      jobs_opt="${1#*=}"
      shift
      ;;
    --log-suffix)
      [ "$#" -lt 2 ] && die "'--log-suffix' expects a suffix argument"
      log_suffix="$2"
      shift 2
      ;;
    --log-suffix=*)
      log_suffix="${1#*=}"
      shift
      ;;
    --time-limit)
      [ "$#" -lt 2 ] && die "'--time-limit' expects an integer in seconds"
      time_limit_opt="$2"
      shift 2
      ;;
    --time-limit=*)
      time_limit_opt="${1#*=}"
      shift
      ;;
    --)
      shift
      forward_args=("$@")
      break
      ;;
    *)
      if [ -z "$cnf_dir" ]; then
        cnf_dir="$1"
        shift
      else
        die "unexpected argument '$1'"
      fi
      ;;
  esac
done

[ -n "$cnf_dir" ] || die "missing CNF directory argument"
[ -d "$cnf_dir" ] || die "CNF directory '$cnf_dir' does not exist"
[ -n "$log_suffix" ] || die "missing required '--log-suffix' value"
case "$log_suffix" in
  *[[:space:]]*)
    die "log suffix must not contain whitespace"
    ;;
esac

if [ -z "$runner" ]; then
  die "could not locate executable run-cadical-mab.sh near '$script_dir'"
fi

cnf_dir_abs="$(cd "$cnf_dir" && pwd)"

if ! help wait 2>/dev/null | grep -q -- '-n'; then
  die "requires bash with 'wait -n' support (upgrade to bash 4.3+)"
fi

printf '[run-batch-mab] preparing MAB build...\n'
"$runner" --build-only

time_limit="${time_limit_opt:-${CADICAL_TIME_LIMIT:-5000}}"
case "$time_limit" in
  ''|*[!0-9]*)
    die "invalid time limit '$time_limit' (use integer seconds, 0 to disable)"
    ;;
esac

if [ -n "$log_dir_opt" ]; then
  case "$log_dir_opt" in
    /*) base_log_dir="$log_dir_opt" ;;
    *) base_log_dir="$cnf_dir_abs/$log_dir_opt" ;;
  esac
else
  base_log_dir="$cnf_dir_abs/logs"
fi
log_dir_abs="${base_log_dir}-${log_suffix}"

mkdir -p "$log_dir_abs"

jobs="${jobs_opt:-${JOBS:-8}}"
case "$jobs" in
  ''|*[!0-9]*)
    die "invalid jobs value '$jobs' (must be positive integer)"
    ;;
  *)
    [ "$jobs" -ge 1 ] || die "jobs value must be at least 1"
    ;;
esac

# Collect CNF files that still need to run.
pending=()
while IFS= read -r -d '' cnf_path; do
  rel="${cnf_path#$cnf_dir_abs/}"
  rel_no_ext="${rel%.*}"
  final_log="$log_dir_abs/$rel_no_ext.log"
  if [ -f "$final_log" ]; then
    printf '[run-batch-mab] skipping %s (log exists)\n' "$rel"
    continue
  fi
  pending+=("$cnf_path")
done < <(find "$cnf_dir_abs" -maxdepth 1 -type f -name '*.cnf' -print0 | sort -z)

if [ "${#pending[@]}" -eq 0 ]; then
  printf '[run-batch-mab] no remaining CNF instances in %s\n' "$cnf_dir_abs"
  exit 0
fi

# Helper to run a single CNF instance.
run_instance() {
  local cnf_abs="$1"
  local rel="${cnf_abs#$cnf_dir_abs/}"
  local rel_no_ext="${rel%.*}"
  local final_log="$log_dir_abs/$rel_no_ext.log"
  local target_dir
  target_dir="$(dirname "$final_log")"
  mkdir -p "$target_dir"

  local base_name safe_base tmp_log status exit_rc start_ts end_ts elapsed summary_line
  base_name="${rel_no_ext##*/}"
  safe_base="$(printf '%s' "$base_name" | tr -c 'A-Za-z0-9._-' '_')"
  [ -n "$safe_base" ] || safe_base="instance"
  tmp_log="$(mktemp "$target_dir/.${safe_base}.XXXXXX.log")"

  printf '[run-batch-mab] start %s\n' "$rel"
  start_ts="$(date +%s.%N)"

  set +e
  if [ "${#forward_args[@]}" -gt 0 ]; then
    CADICAL_SKIP_BUILD=1 "$runner" --time-limit "$time_limit" -- "${forward_args[@]}" "$cnf_abs" >"$tmp_log" 2>&1
  else
    CADICAL_SKIP_BUILD=1 "$runner" --time-limit "$time_limit" "$cnf_abs" >"$tmp_log" 2>&1
  fi
  status=$?
  set -e

  end_ts="$(date +%s.%N)"
  elapsed="$(awk -v start="$start_ts" -v end="$end_ts" 'BEGIN { printf "%.2f", (end - start) }')"
  exit_rc="$status"

  case "$status" in
    10)
      summary_line="SUMMARY: concluded SAT elapsed=${elapsed}s exit=10"
      printf '[run-batch-mab] done  %s (SAT, %ss)\n' "$rel" "$elapsed"
      status=0
      ;;
    20)
      summary_line="SUMMARY: concluded UNSAT elapsed=${elapsed}s exit=20"
      printf '[run-batch-mab] done  %s (UNSAT, %ss)\n' "$rel" "$elapsed"
      status=0
      ;;
    124)
      summary_line="SUMMARY: tle elapsed=${elapsed}s limit=${time_limit}s exit=124"
      printf '[run-batch-mab] TLE   %s (limit %ss)\n' "$rel" "$time_limit"
      ;;
    *)
      summary_line="SUMMARY: error elapsed=${elapsed}s exit=${exit_rc}"
      printf '[run-batch-mab] FAIL  %s (exit %s)\n' "$rel" "$exit_rc" >&2
      ;;
  esac

  printf '\n%s\n' "$summary_line" >>"$tmp_log"
  mv "$tmp_log" "$final_log"

  return "$status"
}

fail_flag=0
running_jobs=0

wait_for_completion() {
  local status
  set +e
  wait -n
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail_flag=1
  running_jobs=$((running_jobs - 1))
}

for cnf_path in "${pending[@]}"; do
  run_instance "$cnf_path" &
  running_jobs=$((running_jobs + 1))
  if [ "$running_jobs" -ge "$jobs" ]; then
    wait_for_completion
  fi
done

while [ "$running_jobs" -gt 0 ]; do
  wait_for_completion
done

exit "$fail_flag"
