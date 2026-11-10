#!/usr/bin/env bash
# Link LinuxServer Saved/{Config/LinuxServer,SaveGames,User} to the WindowsServer
# copies so both paths are the same files.
#
# Idempotent: if the relative symlinks already match, do nothing (no backup).
# First run: merge Linux files into Windows with existing Windows files winning
# (cp -an / no-clobber), take one dated backup of the Linux directories, then
# link. Aborts if a Windows target is a symlink or otherwise unsafe.
set -euo pipefail

usage() {
  echo "usage: beasts-of-bermuda-link-saved.sh <FullBaseDir>" >&2
  exit 1
}

[[ "${1:-}" ]] || usage

BASE="${1%/}"
SAVED_LINUX="${BASE}/LinuxServer/BeastsOfBermuda/Saved"
MARKER="${SAVED_LINUX}/.attoric-linked"

abort() {
  echo "ERROR: $*" >&2
  exit 1
}

is_correct_link() {
  local linux_path="$1"
  local rel="$2"
  local win_path="$3"
  [[ -L "$linux_path" ]] || return 1
  local current
  current="$(readlink "$linux_path")"
  if [[ "$current" == "$rel" ]]; then
    return 0
  fi
  # Absolute or normalized links that already resolve to the Windows dir are OK.
  if [[ -e "$linux_path" && -d "$win_path" ]] &&
    [[ "$(readlink -f "$linux_path")" == "$(readlink -f "$win_path")" ]]; then
    return 0
  fi
  return 1
}

link_saved() {
  local win="$1"
  local linux="$2"
  local rel="$3"
  local kind="$4"

  mkdir -p "$(dirname "$win")" "$(dirname "$linux")"

  if [[ -L "$win" ]]; then
    abort "${kind}: Windows target is a symlink; refusing to continue to avoid loops/data loss: ${win} -> $(readlink "$win")"
  fi

  if [[ -e "$win" && ! -d "$win" ]]; then
    abort "${kind}: Windows target exists and is not a directory: ${win}"
  fi

  if [[ ! -e "$win" ]]; then
    if [[ -L "$linux" ]]; then
      abort "${kind}: Windows target is missing and Linux path is already a symlink (${linux} -> $(readlink "$linux")). Refusing to invent a Windows directory."
    fi
    mkdir -p "$win"
  fi

  if is_correct_link "$linux" "$rel" "$win"; then
    echo "${kind}: already linked -> $(readlink "$linux")"
    # Normalize to the relative target if we accepted a resolvable absolute link.
    if [[ "$(readlink "$linux")" != "$rel" ]]; then
      ln -sfn "$rel" "$linux"
      echo "${kind}: normalized to relative target ${rel}"
    fi
    return 0
  fi

  if [[ -L "$linux" ]]; then
    echo "${kind}: replacing unexpected symlink $(readlink "$linux") with ${rel} (no backup of symlink)"
    ln -sfn "$rel" "$linux"
    return 0
  fi

  if [[ -d "$linux" ]]; then
    local stamp backup
    stamp="$(date -Iseconds)"
    backup="${linux}.linux-backup-${stamp}"
    echo "${kind}: merging Linux files into Windows (existing Windows files win), then backing up Linux dir to ${backup}"
    # No-clobber: never overwrite customer Windows files with Linux defaults.
    cp -an "${linux}/." "${win}/"
    mv "$linux" "$backup"
  fi

  ln -sfn "$rel" "$linux"
  echo "${kind}: linked -> ${rel}"
}

mkdir -p "$SAVED_LINUX"

link_saved \
  "${BASE}/WindowsServer/BeastsOfBermuda/Saved/Config/WindowsServer" \
  "${SAVED_LINUX}/Config/LinuxServer" \
  "../../../../WindowsServer/BeastsOfBermuda/Saved/Config/WindowsServer" \
  "Config"

link_saved \
  "${BASE}/WindowsServer/BeastsOfBermuda/Saved/SaveGames" \
  "${SAVED_LINUX}/SaveGames" \
  "../../../WindowsServer/BeastsOfBermuda/Saved/SaveGames" \
  "SaveGames"

link_saved \
  "${BASE}/WindowsServer/BeastsOfBermuda/Saved/User" \
  "${SAVED_LINUX}/User" \
  "../../../WindowsServer/BeastsOfBermuda/Saved/User" \
  "User"

if [[ ! -f "$MARKER" ]]; then
  date -Iseconds > "$MARKER"
  echo "Wrote marker ${MARKER}"
fi

echo "Linked LinuxServer Config, SaveGames, and User to WindowsServer"
