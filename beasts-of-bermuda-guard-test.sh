#!/usr/bin/env bash
# Local simulation of the Beasts of Bermuda Linux linker + stop-guard wrapper.
# Does not require AMP or the real game server.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d /tmp/bob-guard-test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

BASE="${WORKDIR}/882430"
LINK="${ROOT}/beasts-of-bermuda-link-saved.sh"
RUN="${ROOT}/beasts-of-bermuda-run.sh"
FAILS=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

setup_tree() {
  rm -rf "$BASE"
  mkdir -p \
    "${BASE}/WindowsServer/BeastsOfBermuda/Saved/Config/WindowsServer" \
    "${BASE}/LinuxServer/BeastsOfBermuda/Saved/Config/LinuxServer" \
    "${BASE}/LinuxServer/BeastsOfBermuda/Binaries/Linux" \
    "${BASE}/WindowsServer/BeastsOfBermuda/Saved/SaveGames" \
    "${BASE}/LinuxServer/BeastsOfBermuda/Saved/SaveGames" \
    "${BASE}/WindowsServer/BeastsOfBermuda/Saved/User" \
    "${BASE}/LinuxServer/BeastsOfBermuda/Saved/User"

  printf '%s\n' "WindowsGame=keep-me" > "${BASE}/WindowsServer/BeastsOfBermuda/Saved/Config/WindowsServer/Game.ini"
  printf '%s\n' "LinuxGame=default-should-not-win" > "${BASE}/LinuxServer/BeastsOfBermuda/Saved/Config/LinuxServer/Game.ini"
  printf '%s\n' "WindowsOnly=1" > "${BASE}/WindowsServer/BeastsOfBermuda/Saved/Config/WindowsServer/Engine.ini"
  printf '%s\n' "LinuxOnly=1" > "${BASE}/LinuxServer/BeastsOfBermuda/Saved/Config/LinuxServer/GameUserSettings.ini"
  printf '%s\n' "win-save" > "${BASE}/WindowsServer/BeastsOfBermuda/Saved/SaveGames/slot.sav"
  printf '%s\n' "linux-save" > "${BASE}/LinuxServer/BeastsOfBermuda/Saved/SaveGames/linux.sav"
}

echo "== link_saved first run: Windows files win, one dated backup =="
setup_tree
bash "$LINK" "$BASE"
WIN_GAME="$(cat "${BASE}/WindowsServer/BeastsOfBermuda/Saved/Config/WindowsServer/Game.ini")"
LIN_GAME="$(cat "${BASE}/LinuxServer/BeastsOfBermuda/Saved/Config/LinuxServer/Game.ini")"
if [[ "$WIN_GAME" == "WindowsGame=keep-me" && "$LIN_GAME" == "WindowsGame=keep-me" ]]; then
  pass "Windows Game.ini survived and is visible via the Linux path"
else
  fail "Windows Game.ini not preserved (win='${WIN_GAME}' linux='${LIN_GAME}')"
fi
if grep -q 'WindowsOnly=1' "${BASE}/LinuxServer/BeastsOfBermuda/Saved/Config/LinuxServer/Engine.ini" &&
  grep -q 'LinuxOnly=1' "${BASE}/WindowsServer/BeastsOfBermuda/Saved/Config/WindowsServer/GameUserSettings.ini"; then
  pass "merge copied Linux-only files without clobbering Windows-only files"
else
  fail "merge did not combine Linux-only + Windows-only files"
fi
if [[ -L "${BASE}/LinuxServer/BeastsOfBermuda/Saved/Config/LinuxServer" ]]; then
  pass "Config is a symlink"
else
  fail "Config is not a symlink"
fi
if [[ -f "${BASE}/LinuxServer/BeastsOfBermuda/Saved/.attoric-linked" ]]; then
  pass "marker written"
else
  fail "marker missing"
fi
backups=( "${BASE}"/LinuxServer/BeastsOfBermuda/Saved/Config/LinuxServer.linux-backup-* )
if [[ -d "${backups[0]}" ]]; then
  pass "first-run dated backup created: $(basename "${backups[0]}")"
else
  fail "first-run dated backup missing"
fi
rel="$(readlink "${BASE}/LinuxServer/BeastsOfBermuda/Saved/Config/LinuxServer")"
expected="../../../../WindowsServer/BeastsOfBermuda/Saved/Config/WindowsServer"
if [[ "$rel" == "$expected" ]]; then
  pass "Config relative target is ${rel}"
else
  fail "Config relative target is ${rel}"
fi

echo "== link_saved second run: idempotent, no new backup =="
before_backup_count="$(find "${BASE}/LinuxServer/BeastsOfBermuda/Saved" -maxdepth 2 -type d -name '*.linux-backup-*' | wc -l)"
bash "$LINK" "$BASE"
after_backup_count="$(find "${BASE}/LinuxServer/BeastsOfBermuda/Saved" -maxdepth 2 -type d -name '*.linux-backup-*' | wc -l)"
if [[ "$before_backup_count" -eq "$after_backup_count" ]]; then
  pass "second run created no additional backups (${after_backup_count} total)"
else
  fail "second run created backups (${before_backup_count} -> ${after_backup_count})"
fi
if [[ "$(cat "${BASE}/WindowsServer/BeastsOfBermuda/Saved/Config/WindowsServer/Game.ini")" == "WindowsGame=keep-me" ]]; then
  pass "Windows Game.ini unchanged after second link"
else
  fail "Windows Game.ini changed after second link"
fi

echo "== refuse Windows symlink target =="
bad="${WORKDIR}/badbase"
mkdir -p "${bad}/LinuxServer/BeastsOfBermuda/Saved/Config" "${bad}/WindowsServer/BeastsOfBermuda/Saved/Config"
ln -s /tmp "${bad}/WindowsServer/BeastsOfBermuda/Saved/Config/WindowsServer"
if bash "$LINK" "$bad" >/tmp/bob-link-err.txt 2>&1; then
  fail "linker should abort when Windows Config is a symlink"
else
  pass "linker aborted on Windows symlink target"
fi

echo "== wrapper restores live Game.ini edit after fake SIGTERM rewrite =="
setup_tree
bash "$LINK" "$BASE"
mkdir -p "${BASE}/LinuxServer"
cp "$RUN" "${BASE}/LinuxServer/beasts-of-bermuda-run.sh"
cp "$LINK" "${BASE}/LinuxServer/beasts-of-bermuda-link-saved.sh"
chmod +x "${BASE}/LinuxServer/beasts-of-bermuda-run.sh"

# Fake dedicated server: rewrite Game.ini from "memory" on SIGTERM.
cat > "${BASE}/LinuxServer/BeastsOfBermuda/Binaries/Linux/BeastsOfBermudaServer" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INI="${SCRIPT_DIR}/../../Saved/Config/LinuxServer/Game.ini"
LOADED="$(cat "$INI" 2>/dev/null || true)"
# Simulate in-memory copy taken at start.
on_term() {
  printf '%s\n' "REWRITTEN_FROM_MEMORY_ON_STOP" > "$INI"
  printf '%s\n' "original-in-memory-was:${LOADED}" >> "$INI"
  exit 143
}
trap on_term TERM INT
# Keep stdout alive the way a game server would.
echo "fake server online args=$*"
while true; do sleep 0.2; done
FAKE
chmod +x "${BASE}/LinuxServer/BeastsOfBermuda/Binaries/Linux/BeastsOfBermudaServer"

cd "$BASE"
"${BASE}/LinuxServer/beasts-of-bermuda-run.sh" -Port 7777 >"${WORKDIR}/wrapper.log" 2>&1 &
WRAP_PID=$!
# Wait until start hashes are recorded / child is up.
for _ in $(seq 1 50); do
  if grep -q 'started BeastsOfBermudaServer' "${WORKDIR}/wrapper.log" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
sleep 0.4
printf '%s\n' "CUSTOMER_LIVE_EDIT=1" > "${BASE}/LinuxServer/BeastsOfBermuda/Saved/Config/LinuxServer/Game.ini"
# Give the 1s poller time to snapshot the live edit.
sleep 1.3
kill -TERM "$WRAP_PID"
set +e
wait "$WRAP_PID"
WRAP_RC=$?
set -e
if [[ "$WRAP_RC" -eq 0 ]]; then
  pass "wrapper mapped SIGTERM child death to exit 0 (AMP Stop / OS_CLOSE)"
else
  fail "wrapper exit code was ${WRAP_RC}, expected 0 after graceful SIGTERM"
fi
RESULT="$(cat "${BASE}/WindowsServer/BeastsOfBermuda/Saved/Config/WindowsServer/Game.ini")"
LIN_RESULT="$(cat "${BASE}/LinuxServer/BeastsOfBermuda/Saved/Config/LinuxServer/Game.ini")"
if [[ "$RESULT" == "CUSTOMER_LIVE_EDIT=1" && "$LIN_RESULT" == "CUSTOMER_LIVE_EDIT=1" ]]; then
  pass "wrapper restored live Game.ini edit through both paths after fake rewrite"
else
  fail "live edit not restored (win='${RESULT}' linux='${LIN_RESULT}')"
  echo "----- wrapper.log -----"
  cat "${WORKDIR}/wrapper.log" || true
fi
if grep -q 'REWRITTEN_FROM_MEMORY_ON_STOP' "${BASE}/WindowsServer/BeastsOfBermuda/Saved/Config/WindowsServer/Game.ini"; then
  fail "rewritten Game.ini was left in place"
fi
if grep -q 'started BeastsOfBermudaServer' "${WORKDIR}/wrapper.log"; then
  pass "wrapper forwarded launch and logged child start"
else
  fail "wrapper did not start fake server"
fi

echo
if [[ "$FAILS" -eq 0 ]]; then
  echo "All simulation checks passed."
  exit 0
fi
echo "${FAILS} simulation check(s) failed."
exit 1
