#!/usr/bin/env bash
# AMP Linux executable wrapper for Beasts of Bermuda.
#
# The dedicated server rewrites Game.ini / GameUserSettings.ini / Engine.ini
# from memory on shutdown, which drops customer edits made while the process
# is running. This wrapper:
#   1. Verifies (and if needed, runs) the Saved-dir linker
#   2. Restores any leftover snapshots from a previous SIGKILL
#   3. Records start hashes, polls for on-disk edits, snapshots changed files
#   4. Runs BeastsOfBermudaServer with the original args
#   5. Forwards TERM/INT to the server (AMP App.ExitMethod=OS_CLOSE)
#   6. After the server exits, writes snapshots back through the symlink (cat >)
#
# Not exec: we must run after the child exits. Exit status is the child's.
# shellcheck disable=SC2317 # on_signal is reached via trap, not direct calls
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "${SCRIPT_DIR}/.." && pwd)"
BINARY="${SCRIPT_DIR}/BeastsOfBermuda/Binaries/Linux/BeastsOfBermudaServer"
CONFIG_DIR="${SCRIPT_DIR}/BeastsOfBermuda/Saved/Config/LinuxServer"
SAVED_DIR="${SCRIPT_DIR}/BeastsOfBermuda/Saved"
GUARD="${SAVED_DIR}/.attoric-ini-guard"
LINK_SCRIPT="${SCRIPT_DIR}/beasts-of-bermuda-link-saved.sh"
INIS=(Game.ini GameUserSettings.ini Engine.ini)

CHILD_PID=""
POLLER_PID=""
STOPPING=0
CHILD_RC=0

log() {
  echo "bob-run: $*"
}

die() {
  echo "bob-run: ERROR: $*" >&2
  exit 1
}

file_hash() {
  local f="$1"
  if [[ -f "$f" ]]; then
    sha256sum -- "$f" | awk '{print $1}'
  else
    printf '%s\n' "MISSING"
  fi
}

restore_snaps() {
  local name src dest
  mkdir -p "$CONFIG_DIR"
  for name in "${INIS[@]}"; do
    src="${GUARD}/${name}.snap"
    dest="${CONFIG_DIR}/${name}"
    if [[ -f "$src" ]]; then
      log "restoring ${name} from ini-guard snapshot"
      mkdir -p "$(dirname "$dest")"
      cat "$src" > "$dest"
      rm -f "$src"
    fi
  done
}

snapshot_if_changed() {
  # $1 = overwrite existing snaps (poller: 1, shutdown: 0)
  local overwrite="${1:-1}"
  local name dest start_file start_hash current
  for name in "${INIS[@]}"; do
    dest="${CONFIG_DIR}/${name}"
    start_file="${GUARD}/${name}.start"
    [[ -f "$start_file" ]] || continue
    if [[ "$overwrite" != "1" && -f "${GUARD}/${name}.snap" ]]; then
      continue
    fi
    start_hash="$(cat "$start_file")"
    current="$(file_hash "$dest")"
    if [[ "$current" != "$start_hash" && "$current" != "MISSING" ]]; then
      cat "$dest" > "${GUARD}/${name}.snap"
    fi
  done
}

stop_poller() {
  # Never wait() here: a wait inside a TERM trap races the main wait on the
  # game PID and can make that wait return 0 instead of the child's status.
  if [[ -n "${POLLER_PID}" ]]; then
    kill "${POLLER_PID}" 2>/dev/null || true
  fi
}

# Invoked from TERM/INT traps registered after the child starts.
on_signal() {
  local sig="$1"
  if [[ "${STOPPING}" -eq 1 ]]; then
    if [[ -n "${CHILD_PID}" ]]; then
      kill "-${sig}" "${CHILD_PID}" 2>/dev/null || true
    fi
    return 0
  fi
  STOPPING=1
  log "caught SIG${sig}; snapshotting ini files then forwarding to server pid=${CHILD_PID:-none}"
  # Stop the poller first so a simultaneous rewrite cannot overwrite a good snap.
  stop_poller
  # Keep poller snaps. Only snapshot files that have no snap yet (last ~1s edit).
  snapshot_if_changed 0
  if [[ -n "${CHILD_PID}" ]]; then
    kill "-${sig}" "${CHILD_PID}" 2>/dev/null || true
  fi
}

cleanup_and_restore() {
  stop_poller
  restore_snaps
}

if [[ -f "$LINK_SCRIPT" ]]; then
  /bin/bash "$LINK_SCRIPT" "$BASE" || die "link-saved failed"
else
  log "link script not found at ${LINK_SCRIPT}; verifying existing links only"
fi

[[ -L "$CONFIG_DIR" ]] || die "${CONFIG_DIR} is not a symlink; refusing to start with split Linux/Windows configs"
[[ -x "$BINARY" ]] || die "server binary missing or not executable: ${BINARY}"

mkdir -p "$GUARD"
# Leftover snaps mean a previous stop was SIGKILL'd before restore.
restore_snaps

for name in "${INIS[@]}"; do
  file_hash "${CONFIG_DIR}/${name}" > "${GUARD}/${name}.start"
  log "${name} start hash=$(cat "${GUARD}/${name}.start")"
done

trap 'on_signal TERM' TERM
trap 'on_signal INT' INT
trap 'cleanup_and_restore' EXIT

(
  trap 'exit 0' TERM INT
  while true; do
    snapshot_if_changed 1
    sleep 1
  done
) &
POLLER_PID=$!

"$BINARY" "$@" &
CHILD_PID=$!
log "started BeastsOfBermudaServer pid=${CHILD_PID}"

while true; do
  if wait "${CHILD_PID}"; then
    CHILD_RC=0
    break
  fi
  wait_rc=$?
  # wait returns 128+N both when this shell is interrupted by a trapped
  # signal and when the child dies from a signal. Only retry if the child
  # is still running.
  if kill -0 "${CHILD_PID}" 2>/dev/null; then
    continue
  fi
  CHILD_RC="${wait_rc}"
  break
done

log "server exited rc=${CHILD_RC}"
trap - EXIT
cleanup_and_restore
if [[ -n "${POLLER_PID}" ]]; then
  wait "${POLLER_PID}" 2>/dev/null || true
  POLLER_PID=""
fi
trap - TERM INT
# AMP Stop sends SIGTERM (OS_CLOSE). Treat a child death from TERM/INT as a
# clean stop so the instance is not flagged as crashed.
if [[ "${CHILD_RC}" -eq 143 || "${CHILD_RC}" -eq 130 ]]; then
  log "mapping signal exit ${CHILD_RC} to 0 for AMP stop"
  exit 0
fi
exit "${CHILD_RC}"
