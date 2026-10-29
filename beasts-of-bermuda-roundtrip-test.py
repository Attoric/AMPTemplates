#!/usr/bin/env python3
"""Simulate AMP Generic AutoMap for Beasts of Bermuda Game.ini.

AMP AutoMap updates existing unique keys in place and does not create missing
keys. Repeated Unreal array keys are not mapped, so Import then save must leave
them untouched.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONFIG = json.loads((ROOT / "beasts-of-bermudaconfig.json").read_text())
META = json.loads((ROOT / "beasts-of-bermudametaconfig.json").read_text())
FIXTURE = ROOT / "beasts-of-bermuda-roundtrip.ini"

ARRAY_KEYS = {
    "ServerAdmins",
    "PlayerChatColors",
    "PlayerChatTags",
    "AdminRanks",
    "AdminCommandRules",
    "ProfanityWords",
    "AutoMessages",
    "CreatureLimits",
    "GrowthLimits",
    "WorldEventBuffsToNotUse",
    "DisabledAITypes",
    "WorldEventBuffWeights",
    "AllowedSpeciesGroups",
    "AdminAllowedCommands",
    "AdminBlockedCommands",
    "SteamGroupName",
}

CLEAR_ARRAY_KEYS = {
    "WorldEventBuffsToNotUse",
    "DisabledAITypes",
    "CreatureLimits",
    "GrowthLimits",
    "PlayerChatColors",
    "PlayerChatTags",
}

EMPTY_HEADINGS = {
    "/Script/Engine.GameEngine",
    "/Script/Engine.GameSession",
    "/Script/OnlineSubsystemUtils.IpNetDriver",
    "/Script/Engine.GarbageCollectionSettings",
    "/Script/Engine.Player",
    "/Script/Engine.NetworkSettings",
    "/Script/PacketHandler.EngineHandlerComponentFactory",
    "/Script/Engine.GameUserSettings",
    "/Script/BeastsOfBermuda.RCONHandler",
    "/Script/BeastsOfBermuda.BBGameModeBase",
}


def automap_keys() -> set[tuple[str, str]]:
    keys: set[tuple[str, str]] = set()
    for item in CONFIG:
        pfn = item.get("ParamFieldName") or ""
        if pfn.startswith("AMPDoesNotWrite."):
            continue
        if "." not in pfn:
            continue
        section, key = pfn.rsplit(".", 1)
        if key in ARRAY_KEYS:
            raise SystemExit(f"array key is AutoMapped: {pfn}")
        keys.add((section, key))
    return keys


def parse_ini(text: str) -> list[tuple[str, str | None, str | None, str]]:
    """Return rows of (raw, section, key, value_or_raw)."""
    section = ""
    rows = []
    for raw in text.splitlines():
        stripped = raw.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped[1:-1]
            rows.append((raw, section, None, None))
            continue
        if "=" in raw and not stripped.startswith(";"):
            key, value = raw.split("=", 1)
            rows.append((raw, section, key.strip(), value))
        else:
            rows.append((raw, section, None, None))
    return rows


def simulate(text: str, mapped: set[tuple[str, str]], extra_updates: dict[tuple[str, str], str] | None = None) -> str:
    rows = parse_ini(text)
    imported: dict[tuple[str, str], str] = {}
    for raw, section, key, value in rows:
        if key is None:
            continue
        if (section, key) in mapped:
            imported[(section, key)] = value
    if extra_updates:
        imported.update(extra_updates)
    out = []
    for raw, section, key, value in rows:
        if key is None:
            out.append(raw)
            continue
        if (section, key) in mapped:
            out.append(f"{key}={imported[(section, key)]}")
        else:
            out.append(raw)
    return "\n".join(out) + "\n"


def count_prefix(lines: list[str], prefix: str) -> int:
    return sum(1 for line in lines if line.startswith(prefix))


def main() -> int:
    game_meta = META[0]
    assert game_meta["AutoMap"] is True
    assert game_meta["Importable"] is True
    assert game_meta["ConfigType"] == "ini"
    assert "Subsections" not in game_meta

    mapped = automap_keys()
    source = FIXTURE.read_text()
    roundtrip = simulate(source, mapped)
    mismatches = [
        (a, b)
        for a, b in zip(source.splitlines(), roundtrip.splitlines())
        if a != b
    ]
    if source != roundtrip:
        print("ROUND-TRIP DIFF (expected empty):")
        for a, b in mismatches:
            print(f"- {a}")
            print(f"+ {b}")
        extra = len(roundtrip.splitlines()) - len(source.splitlines())
        if extra:
            print(f"line count delta: {extra}")
        return 1

    print("ROUND-TRIP DIFF:")
    print("(empty)")

    src_lines = source.splitlines()
    assert count_prefix(src_lines, "ServerAdmins=") == 12
    assert count_prefix(src_lines, "PlayerChatColors=") == 14
    assert count_prefix(src_lines, "PlayerChatTags=") == 14
    assert 'AdminRanks=(AdminRank="SuperAdmin",RankLevel=999)' in src_lines
    assert 'AdminRanks=(AdminRank="DefaultAdmin",RankLevel=5)' in src_lines
    assert 'AdminRanks=(AdminRank="Verified",RankLevel=1)' in src_lines
    assert 'AdminCommandRules=(CommandType=EAdminCommands::RestartMap,MinimalRank="Verified")' in src_lines
    assert "ProfanityWords=http" in src_lines
    assert "ProfanityWords=com" in src_lines
    assert not any("Limit=Limit=" in line for line in src_lines)
    assert not any(line.strip() == "[]" for line in src_lines)
    assert not any(line.endswith("=") and not line.startswith(";") for line in src_lines if "=" in line and line.split("=", 1)[1] == "")

    above_clear = []
    seen_clear = False
    for line in src_lines:
        if line.startswith("!") and line.endswith("=ClearArray"):
            seen_clear = True
            key = line[1:].split("=", 1)[0]
            assert key in CLEAR_ARRAY_KEYS, line
        if not seen_clear and line.startswith(("ProfanityWords=", "AutoMessages=", "SteamWorkshopFoliageSaveItemIDs=", "GameServerLoginToken=", "bUpdateFoliageFilesFromWorkshop=")):
            above_clear.append(line.split("=", 1)[0])
    for required in ("ProfanityWords", "AutoMessages", "SteamWorkshopFoliageSaveItemIDs", "GameServerLoginToken", "bUpdateFoliageFilesFromWorkshop"):
        assert required in above_clear, required

    for heading in EMPTY_HEADINGS:
        assert f"[{heading}]" not in source

    assert "Zupaysaurus" not in source
    assert not any(line.startswith("DiscordLink=") for line in src_lines)
    assert not any(line.startswith("PreferredGameExperience=") for line in src_lines)
    assert not any(line.startswith("bConsoleLocked=") for line in src_lines)
    assert not any(line.startswith("ReservedAdminSlots=") for line in src_lines)
    assert not any(line.startswith("DayLength=") for line in src_lines)
    assert "SubmitSteamWorkshopFoliageFiles" not in source

    changed = simulate(
        source,
        mapped,
        extra_updates={
            ("/Script/BeastsOfBermuda.ServerGameInstance", "MapNameOverride"): '"Rival_Shores"'
        },
    )
    src_set = source.splitlines()
    chg_set = changed.splitlines()
    deltas = [(a, b) for a, b in zip(src_set, chg_set) if a != b]
    assert len(src_set) == len(chg_set)
    assert deltas == [
        ('MapNameOverride="Forest_Island"', 'MapNameOverride="Rival_Shores"')
    ], deltas
    print("ONE-FIELD CHANGE: only MapNameOverride")

    for item in CONFIG:
        fn = item.get("FieldName")
        if fn == "AdminRanks":
            assert item.get("DefaultValue") == ""
        if fn and fn.startswith("AdminCommand") and fn != "AdminCommandUsageFormatStyle":
            assert item.get("DefaultValue") == "", fn

    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
