#!/usr/bin/env bash

# Run CaDiCaL with the experimental MAB-enabled restart policy scaffold.
# This rebuilds the solver with the required compile-time flags and then
# invokes it with sensible runtime defaults for the MAB policy selector.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

die() {
  printf 'run-cadical-mab: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/run-cadical-mab.sh [options] [cadical-options...] <instance.cnf>

Options:
  --build-only    Rebuild the MAB-enabled binary and exit without running.
  --skip-build    Reuse the existing binary (skip the make step).
  --time-limit S  Impose a time limit (seconds, default 5000; 0 disables).
  -h, --help      Show this help message.

The script rebuilds CaDiCaL with CADICAL_EXP_STAGNATION,
CADICAL_EXP_MAB, and CADICAL_EXP_TELEMETRY enabled, then runs the solver
with defaults:
  --stagnation=1 --mab-mode=${MAB_MODE:-1}
  --mab-horizon=${MAB_HORIZON:-10000}
  --mab-ucb-c=${MAB_UCB_C:-1.414} --mab-eps=${MAB_EPS:-50}

Override defaults via environment variables or by passing options after the
script name (later occurrences win). Set MAB_TELEMETRY=1 to add
--exp-telemetry=1. You can also set CADICAL_SKIP_BUILD=1 to skip rebuilding or
CADICAL_TIME_LIMIT to override the default time limit.
EOF
}

build_only=0
env_skip="${CADICAL_SKIP_BUILD:-0}"
case "$env_skip" in
  1|true|yes|on) skip_build=1 ;;
  *) skip_build=0 ;;
esac
time_limit="${CADICAL_TIME_LIMIT:-5000}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --build-only)
      build_only=1
      shift
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --time-limit)
      [ "$#" -lt 2 ] && die "'--time-limit' expects an integer number of seconds"
      time_limit="$2"
      shift 2
      ;;
    --time-limit=*)
      time_limit="${1#*=}"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      break
      ;;
    *)
      break
      ;;
  esac
done

if [ "$build_only" -eq 1 ]; then
  skip_build=0
fi

remaining=("$@")
if [ "$build_only" -eq 0 ] && [ "${#remaining[@]}" -lt 1 ]; then
  usage
  exit 1
fi

case "$time_limit" in
  ''|*[!0-9]*)
    die "invalid time limit '$time_limit' (use integer seconds, 0 to disable)"
    ;;
esac

cadical_build_env="${CADICALBUILD:-build}"
case "$cadical_build_env" in
  /*) build_dir="$cadical_build_env" ;;
  *) build_dir="$root/$cadical_build_env" ;;
esac

makefile_path="$build_dir/makefile"

configure_with_experiments() {
  local -a args
  args=(--exp-stagnation --exp-mab --exp-telemetry)
  if [ -n "${CADICAL_CONFIGURE_FLAGS:-}" ]; then
    # shellcheck disable=SC2206
    local -a extra_args=( ${CADICAL_CONFIGURE_FLAGS} )
    args+=("${extra_args[@]}")
  fi

  if [ "$build_dir" = "$root/build" ]; then
    echo "[run-cadical-mab] configuring default build directory with experimental flags..."
    (cd "$root" && ./configure "${args[@]}") >/dev/null 2>&1 || \
      die "failed to configure default build directory"
  else
    mkdir -p "$build_dir"
    echo "[run-cadical-mab] configuring '$build_dir' with experimental flags..."
    (cd "$build_dir" && "$root/configure" "${args[@]}") >/dev/null 2>&1 || \
      die "failed to configure custom build directory '$build_dir'"
  fi
}

needs_configure=0
if [ ! -f "$makefile_path" ]; then
  needs_configure=1
else
  for macro in CADICAL_EXP_STAGNATION CADICAL_EXP_MAB CADICAL_EXP_TELEMETRY; do
    if ! grep -q "$macro" "$makefile_path"; then
      needs_configure=1
      break
    fi
  done
fi

if [ "$needs_configure" -eq 1 ]; then
  configure_with_experiments
  makefile_path="$build_dir/makefile"
  [ -f "$makefile_path" ] || die "configuration failed to generate '$makefile_path'"
  skip_build=0
fi

detect_jobs() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu
  else
    printf '1\n'
  fi
}

jobs="${JOBS:-$(detect_jobs)}"

if [ "$skip_build" -eq 0 ]; then
  echo "[run-cadical-mab] rebuilding CaDiCaL with MAB flags..."
  # Don't pass CPPFLAGS/CXXFLAGS - the makefile already has the experimental
  # flags from configure, and passing empty values would override them.
  make -C "$build_dir" -B -j"$jobs" cadical
else
  echo "[run-cadical-mab] skipping rebuild (reuse existing binary)"
fi

solver="$build_dir/cadical"
[ -x "$solver" ] || die "solver binary '$solver' not found"

if [ "$build_only" -eq 1 ]; then
  exit 0
fi

idx=$((${#remaining[@]} - 1))
cnf="${remaining[$idx]}"
[ -f "$cnf" ] || die "expected CNF file as last argument, got '$cnf'"

declare -a solver_args
if [ "$idx" -gt 0 ]; then
  solver_args=("${remaining[@]:0:$idx}")
else
  solver_args=()
fi

# Check if user already provided MAB/stagnation options
has_mab_opts=0
has_stag_opt=0
for arg in "${solver_args[@]}"; do
  case "$arg" in
    --mab-mode=*|--mab-horizon=*|--mab-ucb-c=*|--mab-eps=*)
      has_mab_opts=1
      ;;
    --stagnation=*)
      has_stag_opt=1
      ;;
  esac
done

declare -a default_opts
default_opts=()

# Only add stagnation if not already provided
if [ "$has_stag_opt" -eq 0 ]; then
  default_opts+=("--stagnation=1")
fi

# Only add MAB defaults if user didn't provide MAB options
if [ "$has_mab_opts" -eq 0 ]; then
  mab_mode="${MAB_MODE:-1}"
  mab_horizon="${MAB_HORIZON:-10000}"
  mab_ucb_c="${MAB_UCB_C:-1.414}"
  mab_eps="${MAB_EPS:-50}"

  default_opts+=(
    "--mab-mode=$mab_mode"
    "--mab-horizon=$mab_horizon"
    "--mab-ucb-c=$mab_ucb_c"
    "--mab-eps=$mab_eps"
  )
fi

if [ "${MAB_TELEMETRY:-0}" = "1" ]; then
  default_opts+=("--exp-telemetry=1")
fi

echo "[run-cadical-mab] running solver..."
set -x
# Prepare optional timeout wrapper if supported and requested.
if [ -n "$time_limit" ] && [ "$time_limit" != "0" ]; then
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=(timeout --preserve-status "$time_limit")
  else
    echo "[run-cadical-mab] warning: 'timeout' command not found; running without time limit" >&2
    time_limit=0
    timeout_cmd=()
  fi
else
  time_limit=0
  timeout_cmd=()
fi

if [ "${#timeout_cmd[@]}" -gt 0 ]; then
  "${timeout_cmd[@]}" "$solver" "${default_opts[@]}" "${solver_args[@]}" "$cnf"
else
  "$solver" "${default_opts[@]}" "${solver_args[@]}" "$cnf"
fi
