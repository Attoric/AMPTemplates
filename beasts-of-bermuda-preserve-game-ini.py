#!/usr/bin/env python3
"""Merge AMP's Game.ini.amp sidecar into the live Game.ini without dropping unknown lines.

AMP Generic Subsections rewrites listed headings and drops anything it did not emit.
This template writes that output to Game.ini.amp and reapplies it onto the live
Game.ini: AMP-owned keys take the sidecar values, every other line and heading
from the live file (and from Game.ini.last-good) is kept. Repeated array lines
and ClearArray rows are de-duplicated by normalized text. A timestamped
Game.ini.bak-<ts> is written before each merge; only the last N backups are kept.

Linux and Wine both use the WindowsServer Game.ini path (LinuxServer is a symlink).
"""
from __future__ import print_function

import argparse
import datetime
import os
import sys

REPEATABLE_FAMILIES = frozenset(
    {
        "CreatureLimits",
        "GrowthLimits",
        "DisabledAITypes",
        "WorldEventBuffsToNotUse",
        "WorldEventBuffWeights",
        "AdminCommandRules",
        "PlayerChatColors",
        "PlayerChatTags",
        "AllowedSpeciesGroups",
        "AutoMessages",
        "ProfanityWords",
        "AdminAllowedCommands",
        "AdminBlockedCommands",
        "ServerAdmins",
        "AdminRanks",
        "SteamWorkshopFoliageSaveItemIDs",
    }
)

KEEP_DEFAULT = 10


def normalize(line):
    s = line.strip()
    if not s or s.startswith("[") or s.startswith(";"):
        return s
    if "=" not in s:
        return s
    key, val = s.split("=", 1)
    return key.strip() + "=" + val.strip()


def family_of(line):
    n = normalize(line)
    if not n or n.startswith("[") or n.startswith(";"):
        return None
    if "=" not in n:
        return None
    key = n.split("=", 1)[0]
    if key.startswith("!") or key.startswith("+"):
        key = key[1:]
    if "(" in key:
        key = key.split("(", 1)[0]
    return key


def parse_ini(text):
    headings = []
    current = None
    buckets = {}
    for raw in text.splitlines():
        s = raw.strip()
        if s.startswith("[") and s.endswith("]") and len(s) >= 2:
            current = s[1:-1]
            if current not in buckets:
                buckets[current] = []
                headings.append(current)
            continue
        if current is None:
            current = ""
            if current not in buckets:
                buckets[current] = []
                headings.append(current)
        buckets[current].append(raw.rstrip("\n"))
    return headings, buckets


def merge_heading(amp_lines, snap_lines):
    amp_norm = [normalize(l) for l in amp_lines]
    seen = set(x for x in amp_norm if x and not x.startswith(";"))
    amp_families = set()
    for line in amp_lines:
        fam = family_of(line)
        if fam:
            amp_families.add(fam)
    out = list(amp_lines)
    for line in snap_lines:
        n = normalize(line)
        if n.startswith("[") and n.endswith("]"):
            continue
        if not n:
            if line.strip() == "" and (out and out[-1].strip() != ""):
                out.append(line)
            continue
        if n.startswith(";"):
            if n not in seen:
                out.append(line)
                seen.add(n)
            continue
        fam = family_of(line)
        if n in seen:
            continue
        if fam and fam in amp_families and fam not in REPEATABLE_FAMILIES:
            continue
        out.append(line)
        seen.add(n)
    return out


def pick_snapshot(live_text, last_good_text):
    def score(text):
        if not text:
            return -1
        _, buckets = parse_ini(text)
        n = 0
        for lines in buckets.values():
            n += sum(1 for l in lines if normalize(l) and not normalize(l).startswith("["))
        return n

    if score(last_good_text) > score(live_text):
        return last_good_text
    return live_text if live_text else last_good_text


def merge_texts(snap_text, amp_text):
    snap_text = snap_text or ""
    amp_text = amp_text or ""
    if not amp_text.strip():
        return snap_text if snap_text.endswith("\n") or snap_text == "" else snap_text + "\n"
    sh, sb = parse_ini(snap_text)
    ah, ab = parse_ini(amp_text)
    order = list(ah)
    for h in sh:
        if h not in order:
            order.append(h)
    chunks = []
    for h in order:
        if h != "":
            chunks.append("[" + h + "]")
        merged = merge_heading(ab.get(h, []), sb.get(h, []))
        chunks.extend(merged)
        if chunks and chunks[-1].strip() != "":
            chunks.append("")
    text = "\n".join(chunks).rstrip() + "\n"
    return text


def rotate_backups(game_ini, keep):
    directory = os.path.dirname(game_ini) or "."
    base = os.path.basename(game_ini)
    prefix = base + ".bak-"
    found = []
    try:
        names = os.listdir(directory)
    except OSError:
        return
    for name in names:
        if name.startswith(prefix):
            found.append(os.path.join(directory, name))
    found.sort()
    extra = len(found) - keep
    if extra <= 0:
        return
    for path in found[:extra]:
        try:
            os.remove(path)
        except OSError:
            pass


def backup(game_ini, keep):
    if not os.path.isfile(game_ini):
        return None
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    bak = game_ini + ".bak-" + ts
    n = 0
    while os.path.exists(bak):
        n += 1
        bak = game_ini + ".bak-" + ts + "-" + str(n)
    with open(game_ini, "rb") as src, open(bak, "wb") as dst:
        dst.write(src.read())
    rotate_backups(game_ini, keep)
    return bak


def read_if(path):
    if not path or not os.path.isfile(path):
        return ""
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


def write_text(path, text):
    directory = os.path.dirname(path)
    if directory and not os.path.isdir(directory):
        os.makedirs(directory)
    tmp = path + ".amp-merge-tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    os.replace(tmp, path)


def run(game_ini, amp_ini, keep):
    last_good = game_ini + ".last-good"
    live = read_if(game_ini)
    snap = pick_snapshot(live, read_if(last_good))
    amp = read_if(amp_ini)
    if not snap and not amp:
        print("preserve-game-ini: no Game.ini yet")
        return 0
    backup(game_ini, keep)
    merged = merge_texts(snap, amp)
    write_text(game_ini, merged)
    write_text(last_good, merged)
    print("preserve-game-ini: merged " + amp_ini + " into " + game_ini)
    return 0


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--game-ini", required=True)
    parser.add_argument("--amp-ini", default="")
    parser.add_argument("--keep", type=int, default=KEEP_DEFAULT)
    args = parser.parse_args(argv)
    amp_ini = args.amp_ini or (args.game_ini + ".amp")
    return run(os.path.abspath(args.game_ini), os.path.abspath(amp_ini), args.keep)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
