#!/usr/bin/env python3
"""Regression sweep for utility mechanics: flasks, charges, auras/reservation, movement speed, onslaught,
curses and keystones/ascendancy text, using real game-data wording.

For each case it checks that:
  - the line exists verbatim in the index (search exact) and the topic query finds sources,
  - parse_mod/what_if handle it as expected (supported, or correctly reported as unsupported),
  - the expected output stat moves in the right direction: directly for unconditional lines, or under
    ifConditionsMet (with `requires` reported) for conditional ones. A conditional line may also move the stat
    directly when the build already meets the condition.

Cases with `xfail` document a known TOOL problem: they report XFAIL while broken and XPASS once fixed, and do not
count as failures.

Usage: python agent/tools/sweeps/utility_sweep.py [--verbose]"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from rpc import call

# label, topic query, real line, output stat, expectation, kind, extra options
#   expectation: "up" | "down" | ("eq", value) | "unsupported" | ("up_or_current_eq", value)
#   kind: "plain" (must move as configured) | "cond" (must report requires; moves directly or under ifConditionsMet)
CASES = [
    # --- flasks ("during Effect" needs Condition:UsingFlask; this build's 5 flasks are all inactive) ---
    dict(label="Flask: crit during effect", query="critical strike chance during effect", line="(38-43)% increased Critical Strike Chance during Effect",
         stat="CritChance", expect="up", kind="cond"),
    dict(label="Flask: move speed during effect", query="movement speed during effect", line="(12-14)% increased Movement Speed during Effect",
         stat="MovementSpeedMod", expect="up", kind="cond"),
    dict(label="Flask: damage during any flask effect", query="during any flask effect", line="(10-12)% increased Damage during any Flask Effect",
         stat="TotalDPS", expect="up", kind="cond"),
    dict(label="Flask: increased effect", query="flasks applied to you have", line="Flasks applied to you have (12-13)% increased Effect",
         stat="FlaskEffect", expect="up", kind="cond"),  # requires: equipped flasks active
    dict(label="Flask: charge generation", query="flasks gain charges every", line="Flasks gain 2 Charges every 3 seconds",
         stat="FlaskChargeGen", expect="up", kind="plain"),
    dict(label="Flask: effect duration", query="flask effect duration", line="(14-15)% increased Flask Effect Duration",
         stat="FlaskDuration", expect="up", kind="plain"),  # no output stat: checked via what_if modTotals
    # --- charges ---
    dict(label="Charges: max endurance", query="maximum endurance charges", line="+1 to Maximum Endurance Charges",
         stat="EnduranceChargesMax", expect="up", kind="plain"),
    dict(label="Charges: max power (in use)", query="maximum power charges", line="+1 to Maximum Power Charges",
         stat="PowerCharges", expect="up", kind="plain"),
    dict(label="Charges: max frenzy", query="maximum frenzy charges", line="+1 to Maximum Frenzy Charges",
         stat="FrenzyChargesMax", expect="up", kind="plain"),
    dict(label="Charges: max endurance while Determination", query="maximum endurance charges determination",
         line="+1 to Maximum Endurance Charges while affected by Determination", stat="EnduranceChargesMax", expect="up", kind="cond"),
    dict(label="Charges: frenzy duration", query="frenzy charge duration", line="(12-15)% increased Frenzy Charge Duration",
         stat="FrenzyChargesDuration", expect="up", kind="plain"),
    dict(label="Charges: damage per frenzy charge", query="per frenzy charge", line="(4-5)% increased Damage per Frenzy Charge",
         stat="TotalDPS", expect="up", kind="cond"),  # per-charge scaling assumed at max charges
    dict(label="Charges: charge generation is ignored by PoB", query="gain an endurance charge every", line="Gain an Endurance Charge every 12 seconds",
         stat="EnduranceCharges", expect="unsupported", kind="plain"),
    # --- auras / reservation ---
    dict(label="Aura: Zealotry effect", query="zealotry aura effect", line="Zealotry has (19-21)% increased Aura Effect",
         stat="TotalDPS", expect="up", kind="plain"),
    dict(label="Aura: ascendancy notable (Champion Inspirational)", query="Inspirational", sources=["passive"], ascendancy="Champion",
         line="30% increased effect of Non-Curse Auras from your Skills", stat="TotalDPS", expect="up", kind="plain"),
    dict(label="Reservation: life efficiency (nothing reserved)", query="life reservation efficiency of skills",
         line="(15-25)% increased Life Reservation Efficiency of Skills", stat="LifeReserved", expect=("down_or_current_eq", 0), kind="plain"),
    # --- movement speed / onslaught ---
    dict(label="Movement: plain boots mod", query="movement speed", slot="boots", line="(14-15)% increased Movement Speed",
         stat="MovementSpeedMod", expect="up", kind="plain"),
    dict(label="Onslaught: on kill", query="onslaught on kill", line="You gain Onslaught for 4 seconds on Kill",
         stat="MovementSpeedMod", expect="up", kind="cond"),
    dict(label="Onslaught: on hit", query="onslaught on hit", line="You gain Onslaught for 4 seconds on Hit",
         stat="MovementSpeedMod", expect="up", kind="cond",
         xfail="PoB limitation: Condition:Onslaught with flags=Hit never applies as a static buff (what_if's note says so; parse_mod shows flags)"),
    # --- curses ---
    dict(label="Curse: increased effect", query="increased effect of your curses", line="(10-15)% increased Effect of your Curses",
         stat="TotalDPS", expect="up", kind="plain"),
    dict(label="Curse: additional curse", query="additional curse", line="You can apply an additional Curse",
         stat="EnemyCurseLimit", expect="up", kind="plain"),
    # --- keystones ---
    dict(label="Keystone: Chaos Inoculation text", query="Chaos Inoculation", sources=["passive:keystone"],
         line="Maximum Life becomes 1, Immune to Chaos Damage", stat="Life", expect=("eq", 1), kind="plain"),
    dict(label="Keystone: Resolute Technique by name", query="Resolute Technique", sources=["passive:keystone"], line="Resolute Technique",
         by_name=True, stat="CritChance", expect=("eq", 0), kind="plain"),
]


def moved(ch, expect):
    if not ch or ch.get("after") is None:
        return False
    b, a = ch["before"], ch["after"]
    if expect == "up":
        return a > b
    if expect == "down" or (isinstance(expect, tuple) and expect[0] == "down_or_current_eq"):
        return a < b
    if isinstance(expect, tuple) and expect[0] == "eq":
        return abs(a - expect[1]) < 1e-9
    return False


def fmt(ch):
    return f"{ch['before']}->{ch['after']}"


def check_data(c):
    """The line must be real game data: found verbatim in some indexed entry (or as an entry name)."""
    p = dict(query=c["line"], exact=True, limit=200)
    if c.get("sources"):
        p["sources"] = c["sources"]
    s = call("search", **p).get("result", {})
    for e in s.get("results") or []:
        if c.get("ascendancy") and e.get("ascendancy") != c["ascendancy"]:
            continue
        if c["line"] in (e.get("lines") or []) or (c.get("by_name") and e.get("name") == c["line"]):
            src = e["src"] + (f" ({e['ascendancy']})" if e.get("ascendancy") else "")
            return True, f"verbatim in {src} {e.get('name') or e.get('id')}"
    return False, f"line not found verbatim in index ({s.get('total', 0)} loose hits)"


def check_topic(c):
    p = dict(query=c["query"], limit=5)
    for k in ("sources", "slot"):
        if c.get(k):
            p[k] = c[k]
    s = call("search", **p).get("result", {})
    return s.get("total", 0) > 0, f"{s.get('total', 0)} hits for {c['query']!r}"


def check_effect(c):
    stat, expect = c["stat"], c["expect"]
    w = call("what_if", mods=[c["line"]], stats=[stat]).get("result", {})
    if "error" in w:
        return False, f"error {w['error']}"
    unsup = w.get("unsupported")
    if expect == "unsupported":
        if unsup:
            return True, f"reported unsupported (PoB ignores it; extra={unsup[0].get('extra')!r})"
        return False, f"expected unsupported, got changed={w.get('changed')}"
    if unsup:
        return False, f"UNSUPPORTED by PoB parser ({unsup[0].get('extra')!r})"
    reqs = [q["desc"] for q in (w.get("requires") or [])]
    if c.get("no_requires") and reqs:
        return False, f"unexpected requires {reqs}"
    ch = (w.get("changed") or {}).get(stat)
    current = (w.get("current") or {}).get(stat)
    if c["kind"] == "cond" and not reqs:
        return False, f"conditional line but no requires reported (changed={ch}, note={w.get('note')})"
    if ch is None:
        tot = next((v for k, v in (w.get("modTotals") or {}).items() if k.split(":")[0] == stat), None)
        if tot:
            ch = {"before": tot["before"], "after": tot["after"]}
    if moved(ch, expect):
        tail = f" (requirement already met on this build: {', '.join(reqs)})" if c["kind"] == "cond" else ""
        return True, f"{stat} {fmt(ch)}{tail}"
    met = w.get("ifConditionsMet") or {}
    mch = (met.get("changed") or {}).get(stat)
    if c["kind"] == "cond" and moved(mch, expect):
        return True, f"{stat} {fmt(mch)} if {', '.join(met.get('assumed') or [])}"
    if isinstance(expect, tuple) and expect[0] == "down_or_current_eq" and current == expect[1]:
        return True, f"{stat} already {current} on this build (nothing to reduce)"
    return False, f"{stat} not moving {expect}: changed={ch} current={current} met={mch} requires={reqs} note={w.get('note')}"


def main():
    verbose = "--verbose" in sys.argv
    fails = xfails = xpasses = 0
    for c in CASES:
        results = [("data", *check_data(c)), ("search", *check_topic(c)), ("effect", *check_effect(c))]
        ok = all(r[1] for r in results)
        xf = c.get("xfail")
        if xf and not ok:
            tag, xfails = "XFAIL", xfails + 1
        elif xf:
            tag, xpasses = "XPASS", xpasses + 1
        elif ok:
            tag = "OK   "
        else:
            tag, fails = "FAIL ", fails + 1
        print(f"{tag} {c['label']}")
        for kind, good, msg in results:
            if verbose or not good:
                print(f"      {'ok ' if good else 'BAD'} {kind:7} {msg}")
        if xf and (verbose or not ok):
            print(f"      known: {xf}")
    n = len(CASES)
    print(f"\n{n - fails - xfails - xpasses}/{n - xfails - xpasses} passed; {xfails} known tool issues (XFAIL), {xpasses} fixed (XPASS)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
