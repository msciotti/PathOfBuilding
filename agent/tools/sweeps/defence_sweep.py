#!/usr/bin/env python3
"""Regression sweep for the agent context layer: DEFENCES, using real game-data wording.

For each defensive mechanic it checks that:
  - search finds sources for it (and that the plain line itself is among the hits when searched exactly),
  - what_if on an unconditional source moves the expected output stat in the expected direction,
  - what_if on a conditional source reports its requirements and moves the stat (as configured, or under
    ifConditionsMet).

Stats were chosen with the loaded build in mind (Gladiator, capped attack block, capped elemental res,
ES nullified by Dissolution of the Flesh): when a stat is capped the sweep watches the over-cap stat.

Usage: python agent/tools/sweeps/defence_sweep.py [--verbose]"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from rpc import call

UP, DOWN = +1, -1

# (label, search query, unconditional line or None, conditional line or None, output stat, direction)
CASES = [
    # resistances and caps
    ("Chaos res", "chaos resistance", "+(20-35)% to Chaos Resistance",
     "+(31-43)% to Chaos Resistance while affected by Herald of Agony", "ChaosResist", UP),
    ("Chaos res -> max hit", "chaos resistance", "+(20-35)% to Chaos Resistance", None, "ChaosMaximumHitTaken", UP),
    ("Chaos res vs DoT", "chaos resistance against damage over time",
     "+(30-40)% Chaos Resistance against Damage Over Time", None, "ChaosResistOverTime", UP),
    ("Elemental res (capped -> overcap)", "all elemental resistances", "+(7-8)% to all Elemental Resistances",
     "+3% Elemental Resistances while holding a Shield", "FireResistOverCap", UP),
    ("Max cold res", "maximum cold resistance", "+1% to all maximum Resistances",
     "+1% to maximum Cold Resistance while affected by Herald of Ice", "ColdResist", UP),
    ("Max res -> EHP", "maximum resistances", "+1% to all maximum Resistances", None, "TotalEHP", UP),
    # block
    ("Spell block", "spell block", "(4-5)% Chance to Block Spell Damage",
     "+(5-8)% Chance to Block Spell Damage while affected by Discipline", "SpellBlockChance", UP),
    ("Max attack block", "max block", "+3% to maximum Chance to Block Attack Damage", None, "BlockChance", UP),
    ("Attack block (capped -> overcap)", "block attack damage", "+(2-3)% Chance to Block Attack Damage",
     "+(5-8)% Chance to Block Attack Damage while affected by Determination", "BlockChanceOverCap", UP),
    # The build has "Blocked Recently" ticked in Config, so this negated condition can't hold; ifConditionsMet
    # only forces conditions on. Kept as a known tool gap.
    ("Max spell block if not blocked", "maximum chance to block spell damage", None,
     "You are at Maximum Chance to Block Spell Damage if you have not Blocked Recently", "SpellBlockChance", UP),
    # spell suppression
    ("Spell suppression", "suppress", "+(6-7)% chance to Suppress Spell Damage",
     "+(20-30)% chance to Suppress Spell Damage if you've Suppressed Spell Damage Recently", "SpellSuppressionChance", UP),
    ("Suppression effect", "prevent suppressed", "Prevent +(1-2)% of Suppressed Spell Damage",
     "Prevent +35% of Suppressed Spell Damage if you have not Suppressed Spell Damage Recently", "SpellSuppressionEffect", UP),
    # armour / evasion / physical reduction
    ("Armour", "armour", "(25-50)% increased Armour", "+5000 to Armour while Frozen", "Armour", UP),
    ("Armour -> phys reduction", "armour", "(25-50)% increased Armour", None, "PhysicalDamageReduction", UP),
    ("Additional phys reduction", "physical damage reduction", "(3-5)% additional Physical Damage Reduction",
     "(13-15)% additional Physical Damage Reduction while Focused", "PhysicalDamageReduction", UP),
    ("Evasion", "evasion rating", "(25-50)% increased Evasion Rating",
     "+(150-250) to Evasion Rating while on Low Life", "Evasion", UP),
    # damage taken
    ("Reduced fire damage taken", "reduced fire damage taken", "(4-6)% reduced Fire Damage taken", None, "FireTakenHitMult", DOWN),
    ("Reduced damage taken per attribute", "reduced damage taken", "1% reduced Damage taken per 250 Strength", None, "PhysicalTakenHitMult", DOWN),
    ("Increased damage taken (full life)", "damage taken while", None, "20% increased Damage taken while on Full Life", "PhysicalTakenHitMult", UP),
    ("Flat phys taken from hits", "physical damage taken from hits", "-(75-50) Physical Damage taken from Hits", None, "PhysicalTakenHitMult", DOWN),
    ("Phys taken as fire", "physical damage taken as", "10% of Physical Damage from Hits taken as Fire Damage", None, "PhysicalMaximumHitTaken", UP),
    # avoidance
    ("Avoid fire damage", "avoid fire damage", "(8-10)% chance to Avoid Fire Damage from Hits",
     "(6-9)% chance to Avoid Elemental Damage from Hits during Soul Gain Prevention", "AvoidFireDamageChance", UP),
    ("Avoid physical damage", "avoid physical damage", "(5-7)% chance to Avoid Physical Damage from Hits",
     "+(8-15)% chance to Avoid Physical Damage from Hits while Phasing", "AvoidPhysicalDamageChance", UP),
    # recovery
    ("Life regen", "life regen", "Regenerate 1% of Life per second",
     "Regenerate 1% of Life per second while on Low Life", "LifeRegenRecovery", UP),
    ("Life leech", "leeched as life", "0.2% of Physical Damage Leeched as Life",
     "(0.8-1.2)% of Damage leeched as Life while affected by Vitality", "LifeLeechRate", UP),
    ("Life recoup", "recoup", "(9-10)% of Damage taken Recouped as Life",
     "25% of Damage taken while Frozen Recouped as Life", "LifeRecoup", UP),
    ("Max life -> EHP", "maximum life", "(3-5)% increased maximum Life", None, "TotalEHP", UP),
]


def moved(diff, stat, direction):
    d = (diff or {}).get(stat)
    return d if d and d.get("delta", 0) * direction > 0 else None


def check_line(line, stat, direction, conditional):
    w = call("what_if", mods=[line], stats=[stat]).get("result", {})
    if w.get("unsupported"):
        return False, f"UNSUPPORTED by PoB parser ({w['unsupported'][0].get('extra')!r})"
    arrow = "up" if direction > 0 else "down"
    d = moved(w.get("changed"), stat, direction)
    met = w.get("ifConditionsMet") or {}
    if d:
        msg = f"{stat} {d['before']:.4g}->{d['after']:.4g}"
        if conditional:
            if not w.get("requires"):
                return False, msg + " but no `requires` reported for a conditional line"
            msg += " (requirement already met as configured)"
        return True, msg
    md = moved(met.get("changed"), stat, direction)
    if md:
        return True, f"{stat} {md['before']:.4g}->{md['after']:.4g} if {', '.join(met.get('assumed') or [])}"
    return False, (f"{stat} did not go {arrow}: changed={w.get('changed')} current={(w.get('current') or {}).get(stat)} "
                   f"requires={w.get('requires')} met={met or None} note={w.get('note')}")


def check_search(query, plain):
    s = call("search", query=query, limit=5).get("result", {})
    total = s.get("total", 0)
    if not total:
        return False, f"search {query!r}: 0 hits"
    if plain:
        e = call("search", query=plain, exact=True, limit=5).get("result", {})
        if not e.get("total"):
            return False, f"search {query!r}: {total} hits, but exact {plain!r} not found in game data"
    return True, f"{total} hits"


def main():
    verbose = "--verbose" in sys.argv
    fails = 0
    for label, query, plain, cond, stat, direction in CASES:
        results = [("search", *check_search(query, plain))]
        if plain:
            results.append(("plain", *check_line(plain, stat, direction, False)))
        if cond:
            results.append(("conditional", *check_line(cond, stat, direction, True)))
        ok = all(r[1] for r in results)
        fails += not ok
        print(f"{'OK  ' if ok else 'FAIL'} {label}", flush=True)
        for kind, good, msg in results:
            if verbose or not good:
                print(f"     {'ok ' if good else 'BAD'} {kind:12} {msg}")
    print(f"\n{len(CASES) - fails}/{len(CASES)} passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
