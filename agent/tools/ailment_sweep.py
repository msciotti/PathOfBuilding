#!/usr/bin/env python3
"""Regression sweep for the agent context layer, using real game-data wording.

For each ailment/debuff immunity it checks that:
  - search finds sources for it,
  - what_if on an unconditional source makes the expected output stat reach full immunity (or the build
    already has it),
  - what_if on a conditional source reports its requirements and reaches immunity under ifConditionsMet.

Usage: python agent/tools/ailment_sweep.py [--verbose]"""
import sys, json
from rpc import call

FULL = {"Immunity": 1}  # boolean outputs are reported as 0/1; everything else is a 0-100 chance

# (label, search query, unconditional line, conditional line or None, output stat)
CASES = [
    ("Poison", "poison immune", "Cannot be Poisoned", "Cannot be Poisoned while Bleeding", "PoisonAvoidChance"),
    ("Bleed", "bleed immune", "Bleeding cannot be inflicted on you", "Immunity to Bleeding and Corrupted Blood during Effect", "BleedAvoidChance"),
    ("Ignite", "ignite immune", "Cannot be Ignited", "Immune to Ignite while affected by Purity of Fire", "IgniteAvoidChance"),
    ("Chill", "chill immune", "Cannot be Chilled", "Immunity to Freeze, Chill, Curses and Stuns during Effect", "ChillAvoidChance"),
    ("Freeze", "freeze immune", "Cannot be Frozen", "Immune to Freeze while affected by Purity of Ice", "FreezeAvoidChance"),
    ("Shock", "shock immune", "Cannot be Shocked", "Immune to Shock while affected by Purity of Lightning", "ShockAvoidChance"),
    ("Elemental ailments", "elemental ailments immune", None, "Immune to Elemental Ailments while Bleeding", "ShockAvoidChance"),
    ("Scorch (via elemental)", "elemental ailments immune", None, "Immune to Elemental Ailments while Bleeding", "ScorchAvoidChance"),
    ("Brittle (via elemental)", "elemental ailments immune", None, "Immune to Elemental Ailments while Bleeding", "BrittleAvoidChance"),
    ("Sap (via elemental)", "elemental ailments immune", None, "Immune to Elemental Ailments while Bleeding", "SapAvoidChance"),
    ("Curse", "curse immune", None, "Immune to Curses while you have at least 25 Rage", "CurseAvoidChance"),
    ("Stun", "stun immune", "Cannot be Stunned", "Cannot be Stunned when on Low Life", "StunAvoidChance"),
    ("Blind", "blind immune", "Cannot be Blinded", "Cannot be Blinded while affected by Precision", "BlindAvoidChance"),
    ("Silence", "silence", "You cannot be Cursed with Silence", None, "SilenceAvoidChance"),
    ("Corrupted Blood", "corrupted blood immune", "Corrupted Blood cannot be inflicted on you", "Grants Immunity to Corrupted Blood for (12-14) seconds if used while affected by Corrupted Blood", "CorruptedBloodImmunity"),
    ("Maim", "maim immune", "You cannot be Maimed", "Grants Immunity to Maim for (12-14) seconds if used while Maimed", "MaimImmunity"),
    ("Hinder", "hinder immune", "You cannot be Hindered", "Grants Immunity to Hinder for (12-14) seconds if used while Hindered", "HinderImmunity"),
    ("Knockback", "knocked back", "Cannot be Knocked Back", None, "KnockbackImmunity"),
]

def full_value(stat):
    return 1 if stat.endswith("Immunity") else 100

def check_line(line, stat, conditional):
    w = call("what_if", mods=[line], stats=[stat]).get("result", {})
    if w.get("unsupported"):
        return False, f"UNSUPPORTED by PoB parser ({w['unsupported'][0].get('extra')!r})"
    current = (w.get("current") or {}).get(stat)
    target = full_value(stat)
    changed = (w.get("changed") or {}).get(stat)
    if changed and changed["after"] >= target:
        return True, f"{stat} {changed['before']}->{changed['after']}"
    met = w.get("ifConditionsMet")
    met_changed = ((met or {}).get("changed") or {}).get(stat)
    if met_changed and met_changed["after"] >= target:
        return True, f"{stat} {met_changed['before']}->{met_changed['after']} if {', '.join(met['assumed'])}"
    if current is not None and current >= target:
        return True, f"{stat} already {current} on this build"
    return False, f"{stat} not reaching {target}: changed={changed} met={met} requires={w.get('requires')} note={w.get('note')}"

def main():
    verbose = "--verbose" in sys.argv
    fails = 0
    for label, query, plain, cond, stat in CASES:
        s = call("search", query=query, limit=5).get("result", {})
        results = [("search", s.get("total", 0) > 0, f"{s.get('total', 0)} hits")]
        if plain:
            results.append(("plain", *check_line(plain, stat, False)))
        if cond:
            results.append(("conditional", *check_line(cond, stat, True)))
        ok = all(r[1] for r in results)
        fails += not ok
        print(f"{'OK  ' if ok else 'FAIL'} {label}")
        for kind, good, msg in results:
            if verbose or not good:
                print(f"     {'ok ' if good else 'BAD'} {kind:12} {msg}")
    print(f"\n{len(CASES) - fails}/{len(CASES)} passed")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
