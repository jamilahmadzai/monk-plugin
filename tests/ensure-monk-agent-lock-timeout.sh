#!/usr/bin/env sh
# Regression coverage for a wedged concurrent installer: every shipped POSIX
# bootstrap must stop waiting after the configured lock deadline.
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fixture_bin="$repo_root/tests/fixtures/ensure-monk-agent-lock"
work_dir="$(mktemp -d)"
holder_pid=""
watchdog_pid=""

cleanup() {
  if [ -n "$watchdog_pid" ]; then
    kill "$watchdog_pid" 2>/dev/null || true
  fi
  if [ -n "$holder_pid" ]; then
    kill "$holder_pid" 2>/dev/null || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

case_no=0
for ensure_script in \
  "$repo_root/scripts/ensure-monk-agent.sh" \
  "$repo_root/plugins/monk/scripts/ensure-monk-agent.sh" \
  "$repo_root/.antigravity-plugin/scripts/ensure-monk-agent.sh"
do
  case_no=$((case_no + 1))
  case_dir="$work_dir/case-$case_no"
  install_dir="$case_dir/install"
  ready_file="$case_dir/holder-ready"
  output_file="$case_dir/output"
  timeout_marker="$case_dir/watchdog-fired"
  mkdir -p "$install_dir"

  python3 - "$install_dir/.monk-agent.lock" "$ready_file" <<'PY' &
import fcntl
import pathlib
import sys
import time

lock_path, ready_path = sys.argv[1:]
with open(lock_path, "w", encoding="utf-8") as lock_file:
    fcntl.flock(lock_file, fcntl.LOCK_EX)
    pathlib.Path(ready_path).touch()
    time.sleep(30)
PY
  holder_pid=$!

  waited=0
  while [ ! -e "$ready_file" ]; do
    waited=$((waited + 1))
    if [ "$waited" -ge 50 ]; then
      echo "lock holder did not become ready for $ensure_script" >&2
      exit 1
    fi
    sleep 0.1
  done

  set +e
  PATH="$fixture_bin:$PATH" \
  MONK_AGENT_INSTALL_DIR="$install_dir" \
  MONK_AGENT_INSTALL_LOCK_TIMEOUT=1 \
    "$ensure_script" >"$output_file" 2>&1 &
  ensure_pid=$!
  set -e

  (
    sleep 5
    : >"$timeout_marker"
    kill "$ensure_pid" 2>/dev/null || true
  ) &
  watchdog_pid=$!

  set +e
  wait "$ensure_pid"
  status=$?
  set -e
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  watchdog_pid=""

  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  holder_pid=""

  if [ -e "$timeout_marker" ]; then
    echo "$ensure_script waited indefinitely for the install lock" >&2
    exit 1
  fi
  if [ "$status" -eq 0 ]; then
    echo "$ensure_script unexpectedly succeeded while the install lock was held" >&2
    exit 1
  fi
  if ! grep -Fq "Timed out after 1s waiting for another monk-agent install." "$output_file"; then
    echo "$ensure_script did not explain the bounded lock failure" >&2
    cat "$output_file" >&2
    exit 1
  fi
done

echo "ensure-monk-agent lock-timeout tests passed."
