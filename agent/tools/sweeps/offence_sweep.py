#!/usr/bin/env python3
"""Offence regression sweep for the agent context layer, using real game-data wording.

Written against the level 87 Gladiator build whose main skill is Divine Retribution (a Physical/Lightning
area SPELL with a 4s cooldown, Sacrifice adds a large Chaos part, socketed in the Body Armour).

For each case it:
  - searches with `query` and picks the first real game-data line matching `pick` (so wording is real),
  - checks PoB's parser supports it (parse_mod),
  - runs what_if and checks the expected output stats move in the expected direction:
      "up"/"down"  stat must change that way (directly, or under ifConditionsMet when cond=True)
      "same"       stat must NOT change (mod is irrelevant to this skill, e.g. attack-only on a spell)

Usage: python agent/tools/sweeps/offence_sweep.py [--verbose]"""
import os, re, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from rpc import call

DPS = "TotalDPS"
# (label, search query, regex picking a real line, {stat: direction}, conditional?)
CASES = [
    ("Spell damage", "increased spell damage", r"^\(\d+-\d+\)% increased Spell Damage$", {DPS: "up", "AverageHit": "up"}, False),
    ("Lightning damage", "increased lightning damage", r"^\(\d+-\d+\)% increased Lightning Damage$", {"LightningHitAverage": "up", DPS: "up", "PhysicalHitAverage": "same"}, False),
    ("Global physical damage", "global physical damage", r"^\(\d+-\d+\)% increased Global Physical Damage$", {"PhysicalHitAverage": "up", DPS: "up"}, False),
    ("Chaos damage", "increased chaos damage", r"^\(\d+-\d+\)% increased Chaos Damage$", {"ChaosHitAverage": "up", DPS: "up"}, False),
    ("Global crit multi", "crit multi", r"^\+\(\d+-\d+\)% to Global Critical Strike Multiplier$", {"CritMultiplier": "up", DPS: "up"}, False),
    ("Spell crit chance", "critical strike chance spells", r"^\(\d+-\d+\)% increased Critical Strike Chance for Spells$", {"CritChance": "up", DPS: "up"}, False),
    ("Lightning penetration", "penetrates lightning", r"^Damage Penetrates \(\d+-\d+\)% Lightning Resistance$", {"LightningHitAverage": "up", DPS: "up", "PhysicalHitAverage": "same"}, False),
    ("Elemental penetration", "penetrates elemental", r"^Damage Penetrates \(\d+-\d+\)% Elemental Resistances$", {"LightningHitAverage": "up", DPS: "up"}, False),
    ("Added lightning to spells", "adds lightning spells", r"^Adds \(\d+-\d+\) to \(\d+-\d+\) Lightning Damage to Spells$", {"LightningHitAverage": "up", DPS: "up"}, False),
    ("Added lightning to attacks (irrelevant)", "adds lightning attacks", r"^Adds \(\d+-\d+\) to \(\d+-\d+\) Lightning Damage to Attacks$", {DPS: "same", "AverageHit": "same"}, False),
    ("Attack speed (irrelevant)", "increased attack speed", r"^\(\d+-\d+\)% increased Attack Speed$", {DPS: "same", "Speed": "same"}, False),
    ("Cast speed (cooldown-bound)", "increased cast speed", r"^\(\d+-\d+\)% increased Cast Speed$", {"CastRate": "up", "Speed": "same", DPS: "same"}, False),
    ("Cooldown recovery", "cooldown recovery", r"^\(\d+-\d+\)% increased Cooldown Recovery Rate$", {"Cooldown": "down", "Speed": "up", DPS: "up"}, False),
    ("+lvl lightning spell gems", "spell skill gems", r"^\+\d+ to Level of all Lightning Spell Skill Gems$", {"AverageHit": "up", DPS: "up"}, False),
    ("+lvl physical spell gems", "spell skill gems", r"^\+\d+ to Level of all Physical Spell Skill Gems$", {"AverageHit": "up", DPS: "up"}, False),
    ("+lvl fire spell gems (irrelevant)", "spell skill gems", r"^\+\d+ to Level of all Fire Spell Skill Gems$", {DPS: "same"}, False),
    ("+lvl socketed gems (body armour)", "level socketed gems", r"^\+\d+ to Level of Socketed Gems$", {"AverageHit": "up", DPS: "up"}, False),
    ("Double damage", "double damage", r"^\d+% chance to deal Double Damage$", {"AverageHit": "up", DPS: "up"}, False),
    ("Poison chance (spell can poison)", "chance to poison on hit", r"^\d+% chance to Poison on Hit$", {"PoisonChance": "up", "PoisonDPS": "up"}, False),
    ("Bleed chance (spells can't bleed)", "chance to cause bleeding on hit", r"^\d+% chance to cause Bleeding on Hit$", {"BleedDPS": "same", "CombinedDPS": "same"}, False),
    ("Added fire to spells -> ignite", "adds fire spells", r"^Adds \(\d+-\d+\) to \(\d+-\d+\) Fire Damage to Spells$", {"IgniteDPS": "up", "CombinedDPS": "up"}, False),
    ("Shock effect", "effect of shock", r"^\(\d+-\d+\)% increased Effect of Shock$", {"ShockEffectMod": "up"}, False),
    ("Lightning exposure", "exposure lightning", r"^\(\d+-\d+\)% chance to inflict Lightning Exposure on Hit$", {DPS: "up"}, True),  # unlocks the Config exposure checkbox
    ("Damage while Leeching (conditional)", "damage while leeching", r"^\(\d+-\d+\)% increased Damage while Leeching$", {DPS: "up"}, True),
    ("Cast speed if Hit Recently (conditional)", "cast speed hit recently", r"^\(\d+-\d+\)% increased Attack and Cast Speed if you've Hit an Enemy Recently$", {"CastRate": "up", DPS: "same"}, True),
]

def pick_line(query, pattern):
    r = call("search", query=query, limit=2000).get("result") or {}
    rx = re.compile(pattern)
    for e in r.get("results") or []:
        for l in e["lines"]:
            if rx.search(l):
                return l, r.get("total", 0), e["src"]
    return None, r.get("total", 0), None

def moved(d, stat, direction):
    c = (d or {}).get(stat)
    if direction == "same":
        return c is None
    if c is None:
        return False
    return c["after"] > c["before"] if direction == "up" else c["after"] < c["before"]

def fmt(d, stat):
    c = (d or {}).get(stat)
    return "unchanged" if c is None else f"{c['before']:.4g}->{c['after']:.4g}"

def check(line, expect, cond):
    w = call("what_if", mods=[line], stats=list(expect)).get("result") or {}
    if w.get("unsupported"):
        return False, f"UNSUPPORTED by PoB parser ({w['unsupported'][0].get('extra')!r})"
    direct = w.get("changed") or {}
    met = w.get("ifConditionsMet") or {}
    msgs, ok = [], True
    for stat, direction in expect.items():
        good = moved(direct, stat, direction)
        how = fmt(direct, stat)
        if not good and cond and direction != "same" and moved(met.get("changed"), stat, direction):
            good, how = True, fmt(met.get("changed"), stat) + f" if {', '.join(met.get('assumed') or [])}"
        if cond and direction == "same":  # must stay put in both evaluations
            good = good and moved(met.get("changed"), stat, "same")
        ok &= good
        msgs.append(f"{stat} {direction}: {how}{'' if good else ' <-- expected ' + direction}")
    if cond and not w.get("requires"):
        ok = False
        msgs.append("expected `requires` for a conditional line")
    if not ok and w.get("note"):
        msgs.append(f"note={w['note']!r}")
    return ok, "; ".join(msgs)

def main():
    verbose = "--verbose" in sys.argv
    fails = 0
    for label, query, pattern, expect, cond in CASES:
        line, total, src = pick_line(query, pattern)
        results = [("search", line is not None, f"{total} hits; picked {line!r} from {src}")]
        if line:
            results.append(("what_if", *check(line, expect, cond)))
        ok = all(r[1] for r in results)
        fails += not ok
        print(f"{'OK  ' if ok else 'FAIL'} {label}")
        for kind, good, msg in results:
            if verbose or not good:
                print(f"     {'ok ' if good else 'BAD'} {kind:8} {msg}")
    print(f"\n{len(CASES) - fails}/{len(CASES)} passed")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
