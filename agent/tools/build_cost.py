#!/usr/bin/env python3
"""build_cost — estimate what it costs to BUY the build currently open in Path of Building.

Pipeline:
  1. PoB bridge `export_build`  -> equipped items + gems
  2. PoB bridge `trade_queries` -> "buy similar" trade-site queries for rares/magics (PoB's own matcher)
  3. Price:
       uniques / gems / cluster-less jewels -> poe.ninja (fast, no rate limit)
       rares / magic flasks                 -> official trade API: cheapest N instant-buyout listings, median
  4. Report per-slot price, confidence, source, and a total in chaos + divine.

Pricing rules (see agent/skills/build-cost/SKILL.md):
  uniques          poe.ninja (link-aware). Mod-pool uniques (Watcher's Eye, Balance of Terror...) -> trade with rolls.
  gems             poe.ninja; level 18+ bought at 20.
  rares            trade, on the 2-4 mods PoB says matter most to the build; needs >= --min-listings listings.
  cluster jewels   trade, notables + exact passive count.
  magic flasks     cheapest normal base (you roll it yourself).

Usage:
  build_cost.py [--league Covens] [--looseness 0.8] [--json] [--no-trade]
Env:
  POB_AGENT_PORT  bridge port (49090)
  POE_TRADE_BASE  trade API base (default https://www.pathofexile.com). GGG blocks datacenter IPs: run from home.
  POESESSID       optional session cookie for the trade API.
"""
import argparse, json, os, statistics, sys, time, urllib.parse
from pathlib import Path

import requests

sys.path.insert(0, os.path.dirname(__file__))
from rpc import call  # noqa: E402

UA = os.environ.get("POB_COST_UA", "pob-agent-build-cost/0.1")
NINJA = "https://poe.ninja/poe1/api"
CACHE = Path(os.environ.get("POB_COST_CACHE", Path.home() / ".cache" / "pob-build-cost"))
CACHE.mkdir(parents=True, exist_ok=True)
NINJA_TTL = 3600
TRADE_TTL = 1800
S = requests.Session()
S.headers["User-Agent"] = UA


# ---------------------------------------------------------------- poe.ninja
def _cached_get(url, ttl, key):
    f = CACHE / (key.replace("/", "_") + ".json")
    if f.exists() and time.time() - f.stat().st_mtime < ttl:
        return json.loads(f.read_text())
    r = S.get(url, timeout=30)
    r.raise_for_status()
    f.write_text(r.text)
    return r.json()


def current_league():
    st = _cached_get(f"{NINJA}/data/index-state", NINJA_TTL, "index-state")
    for lg in st["economyLeagues"]:
        n = lg["name"]
        if n not in ("Standard", "Hardcore") and "Hardcore" not in n and "Ruthless" not in n:
            return n
    return "Standard"


class Ninja:
    ITEM_TYPES = ["UniqueWeapon", "UniqueArmour", "UniqueAccessory", "UniqueJewel", "UniqueFlask",
                  "SkillGem", "ClusterJewel"]

    def __init__(self, league):
        self.league = league
        self.items = {}
        for t in self.ITEM_TYPES:
            url = f"{NINJA}/economy/stash/current/item/overview?league={urllib.parse.quote(league)}&type={t}"
            self.items[t] = _cached_get(url, NINJA_TTL, f"ninja-{league}-{t}")["lines"]
        cur = _cached_get(f"{NINJA}/economy/stash/current/currency/overview?league={urllib.parse.quote(league)}&type=Currency",
                          NINJA_TTL, f"ninja-{league}-Currency")
        self.chaos_per = {"chaos": 1.0}
        trade_ids = {d["name"]: d.get("tradeId") for d in cur.get("currencyDetails", [])}
        for ln in cur["lines"]:
            tid = trade_ids.get(ln["currencyTypeName"])
            if tid and ln.get("chaosEquivalent"):
                self.chaos_per[tid] = ln["chaosEquivalent"]
        # Use the divine rate implied by ninja's own item rows so chaos/divine figures match the site.
        ratios = sorted(r["chaosValue"] / r["divineValue"] for t in ("UniqueArmour", "UniqueAccessory")
                        for r in self.items[t] if (r.get("divineValue") or 0) >= 1)
        self.divine = ratios[len(ratios) // 2] if ratios else self.chaos_per.get("divine", 150.0)
        self.chaos_per["divine"] = self.divine

    def unique(self, item):
        name = item["name"]
        if name.startswith("Foulborn "):
            name = name[len("Foulborn "):]
        types = ["UniqueJewel"] if "Jewel" in (item.get("type") or "") else \
                ["UniqueFlask"] if item.get("type") == "Flask" else ["UniqueWeapon", "UniqueArmour", "UniqueAccessory"]
        rows = [r for t in types for r in self.items[t] if r["name"] == name]
        if not rows:
            return None
        links = item.get("links") or 0
        if any(r.get("links") for r in rows):
            want = 6 if links >= 6 else 5 if links == 5 else None
            pick = [r for r in rows if r.get("links") == want] or [r for r in rows if not r.get("links")] or rows
        else:
            pick = rows
        # several variants (e.g. Watcher's Eye rows, legacy versions) -> cheapest well-listed row = floor
        pick.sort(key=lambda r: (r.get("listingCount", 0) < 5, r["chaosValue"]))
        r = pick[0]
        conf = "high" if r.get("listingCount", 0) >= 20 else "medium" if r.get("listingCount", 0) >= 5 else "low"
        note = f"{r.get('links')}L" if r.get("links") else ""
        if len(rows) > 1 and not any(x.get("links") for x in rows) and len({x.get('variant') for x in rows}) > 1:
            conf, note = "low", f"{len(rows)} variants on ninja, took cheapest"
        return {"chaos": r["chaosValue"], "confidence": conf, "source": "poe.ninja", "note": note,
                "listings": r.get("listingCount")}

    def gem(self, g):
        names = {g["name"], g["name"] + " Support"}
        rows = [r for r in self.items["SkillGem"] if r["name"] in names]
        if not rows:
            return None
        lvl, q, corr = g.get("level") or 1, g.get("quality") or 0, g.get("corrupted")
        # Swap-cost assumption: a gem levelled to 18+ is bought at 20 (21 if it's above 20); lower ones bought at level 1.
        want_lvl = 21 if lvl > 20 else 20 if lvl >= 18 else 1
        want_q = 20 if q >= 20 else None
        def ok(r):
            return (r.get("gemLevel") == want_lvl and (r.get("gemQuality") or None) == want_q
                    and bool(r.get("corrupted")) == bool(corr))
        pick = [r for r in rows if ok(r)]
        if not pick:  # relax: any quality / corruption at that level, then any row
            pick = [r for r in rows if r.get("gemLevel") == want_lvl] or rows
        pick.sort(key=lambda r: r["chaosValue"])
        r = pick[0]
        conf = "high" if r.get("listingCount", 0) >= 20 else "medium"
        return {"chaos": r["chaosValue"], "confidence": conf, "source": "poe.ninja",
                "note": f"bought as {r.get('variant') or want_lvl}", "listings": r.get("listingCount")}


# ---------------------------------------------------------------- trade API
class TradeBlocked(Exception):
    pass


class Trade:
    def __init__(self, league, base, chaos_per):
        self.league, self.base, self.chaos_per = league, base.rstrip("/"), chaos_per
        self.s = requests.Session()
        self.s.headers.update({"User-Agent": UA, "Content-Type": "application/json"})
        if os.environ.get("POESESSID"):
            self.s.cookies.set("POESESSID", os.environ["POESESSID"], domain=".pathofexile.com")
        self.next_ok = 0.0

    def _respect(self, r):
        # X-Rate-Limit-Ip: "8:10:60,15:60:120" ; state "1:10:0,..." -> sleep proactively near the cap
        rules, state = r.headers.get("X-Rate-Limit-Ip"), r.headers.get("X-Rate-Limit-Ip-State")
        wait = 1.5
        if rules and state:
            for rule, st in zip(rules.split(","), state.split(",")):
                mx, per, _ = (int(x) for x in rule.split(":"))
                cur = int(st.split(":")[0])
                if cur >= mx - 1:
                    wait = max(wait, per)
                # else: burst freely — only block when a window is about to fill (GGG locks out on overrun)
        if wait > 900:
            raise RuntimeError(f"GGG trade rate budget exhausted (would need to wait {int(wait/60)} min); try later")
        if wait > 30:
            print(f"[build_cost] rate limit near cap, sleeping {int(wait)}s", file=sys.stderr, flush=True)
        self.next_ok = time.time() + wait

    def _req(self, method, url, **kw):
        for attempt in range(4):
            time.sleep(max(0, self.next_ok - time.time()))
            r = self.s.request(method, url, timeout=30, **kw)
            self._respect(r)
            if r.status_code == 429:
                time.sleep(int(r.headers.get("Retry-After", "10")) + 1)
                continue
            if r.status_code == 403:
                raise TradeBlocked("trade API 403: GGG blocks datacenter/VPN IPs; run from a home connection")
            r.raise_for_status()
            return r.json()
        raise RuntimeError("trade API rate-limited 4x in a row")

    def _cached(self, kind, payload, fn, ttl=TRADE_TTL):
        import hashlib
        key = f"trade-{kind}-" + hashlib.sha1((json.dumps(payload, sort_keys=True) + self.league).encode()).hexdigest()[:16]
        f = CACHE / (key + ".json")
        if f.exists() and time.time() - f.stat().st_mtime < ttl:
            return json.loads(f.read_text())
        out = fn()
        f.write_text(json.dumps(out))
        return out

    def search(self, query, ttl=TRADE_TTL):
        """POST search -> {id, total, ids}. Cheap way to learn the listing count without fetching."""
        lg = urllib.parse.quote(self.league)
        def go():
            sr = self._req("POST", f"{self.base}/api/trade/search/{lg}", data=json.dumps(query))
            return {"id": sr.get("id"), "total": sr.get("total", 0), "ids": sr.get("result", [])[:20],
                    "url": f"https://www.pathofexile.com/trade/search/{lg}/{sr.get('id')}"}
        return self._cached("s", query, go, ttl)

    def fetch_prices(self, sr, n=10, ttl=TRADE_TTL):
        def go():
            prices = []
            ids = sr["ids"][:n]
            for i in range(0, len(ids), 10):
                fr = self._req("GET", f"{self.base}/api/trade/fetch/{','.join(ids[i:i+10])}?query={sr['id']}")
                for res in fr.get("result") or []:
                    pr = ((res or {}).get("listing") or {}).get("price") or {}
                    rate = self.chaos_per.get(pr.get("currency"))
                    if rate and pr.get("amount"):
                        prices.append(round(pr["amount"] * rate, 1))
            return sorted(prices)
        return self._cached("f", {"q": sr["id"], "n": n}, go, ttl)


def build_query(base_query, frags):
    """Rebuild a trade query keeping only the given per-mod fragments."""
    q = json.loads(json.dumps(base_query))
    stats = [{"type": "and", "filters": []}]
    for fr in frags:
        if fr["kind"] == "and":
            stats[0]["filters"].append(fr["filter"])
        else:
            stats.append({"type": "count", "value": {"min": 1}, "filters": fr["filters"]})
    q["query"]["stats"] = stats
    return q


def key_mods(mods, max_key, base=""):
    """Cluster jewels: the notables ARE the item -> search exactly the notables, nothing else (size is pinned by type).
    Mods ordered by PoB-measured build impact. Zero-impact mods (PoB couldn't measure, e.g. cluster notables,
    jewels in tree sockets) fall back to item order with implicits/notables first."""
    if "Cluster Jewel" in (base or ""):
        notables = [m for m in mods if "Added Passive Skill is" in m["text"]]
        if notables:
            # passive count matters too (8-passive Large = fewer filler smalls): pin it exactly
            for m in mods:
                if m["text"].startswith("Adds ") and "Passive Skills" in m["text"] and m.get("value"):
                    pc = json.loads(json.dumps(m))
                    pc["frag"]["filter"]["value"] = {"min": int(m["value"]), "max": int(m["value"])}
                    notables = notables + [pc]
                    break
            return notables, "cluster notables"
    scored = [m for m in mods if m.get("impact", 0) >= 1.0]
    if scored:
        return sorted(scored, key=lambda m: -m["impact"])[:max_key], "build impact"
    def prio(m):
        t = m["text"]
        if "Added Passive Skill is" in t: return 0
        if m["type"] == "implicit": return 1
        if "Adds # Passive Skills" in t or "Jewel Socket" in t: return 3
        return 2
    return sorted(mods, key=prio)[:min(3, max_key)], "fallback (no measurable impact)"


def price_rare(trade, q, a):
    """Walk from the full key-mod set down, dropping the least important mod each step, and take the most
    specific combo that has a real market (>= min_listings). Price = median of the cheapest `listings`."""
    keys, how = key_mods(q["mods"], a.max_key, q.get("base"))
    if how == "cluster notables":
        # all-or-nothing: a cluster missing one of its notables is a different item
        query = build_query(q["query"], [m["frag"] for m in keys])
        sr = trade.search(query)
        ps = trade.fetch_prices(sr, a.listings) if sr["total"] else []
        if not ps:
            return dict(chaos=None, confidence="none", source="trade", listings=sr["total"], url=sr["url"],
                        note="no listings with these notables")
        conf = "high" if sr["total"] >= a.min_listings else "low"
        return dict(chaos=statistics.median(ps), low=ps[0], high=ps[-1], confidence=conf, source="trade",
                    listings=sr["total"], url=sr["url"], keyMods=[m["text"] for m in keys],
                    note=f"cluster: {len([k for k in keys if 'Added Passive Skill is' in k['text']])} notables + exact passive count, median of {len(ps)} cheapest")
    tried = []
    for k in range(len(keys), 0, -1):
        combo = keys[:k]
        query = build_query(q["query"], [m["frag"] for m in combo])
        sr = trade.search(query)
        tried.append({"mods": [m["text"] for m in combo], "listings": sr["total"], "url": sr["url"]})
        if sr["total"] >= a.min_listings:
            ps = trade.fetch_prices(sr, a.listings)
            if not ps:
                continue
            med = statistics.median(ps)
            conf = "high" if sr["total"] >= 30 and k >= min(3, len(keys)) else "medium" if k >= 2 else "low"
            dropped = [m["text"] for m in keys[k:]]
            note = f"{k}/{len(keys)} key mods ({how}), median of {len(ps)} cheapest"
            if dropped:
                note += "; dropped: " + ", ".join(d[:28] for d in dropped)
            return dict(chaos=med, low=ps[0], high=ps[-1], confidence=conf, source="trade",
                        listings=sr["total"], url=sr["url"], note=note,
                        keyMods=[m["text"] for m in combo], tried=tried)
    return dict(chaos=None, confidence="none", source="trade", tried=tried,
                note=f"no combo of key mods reached {a.min_listings} listings")


def price_variable_unique(trade, q, a, ninja_row):
    """Uniques that roll from a mod pool (Watcher's Eye, Balance of Terror, Forbidden Flame...): price real listings of
    THIS unique with THESE rolled mods. Ladder: all mods at 80% of roll -> all mods, any roll -> drop weakest mod."""
    mods = q["mods"]
    def strip(fr):
        fr = json.loads(json.dumps(fr))
        for f in ([fr["filter"]] if fr["kind"] == "and" else fr["filters"]):
            if "value" in f and "option" not in f["value"] and "timeless" not in f["id"]:
                f.pop("value")
        return fr
    ladder = [("all mods, ~80% rolls", [m["frag"] for m in mods]),
              ("all mods, any roll", [strip(m["frag"]) for m in mods])]
    if len(mods) > 1:
        for i in range(len(mods)):  # one mod relaxed away; keep the most common relaxation that has a market
            ladder.append((f"without '{mods[i]['text'][:34]}'", [strip(m["frag"]) for j, m in enumerate(mods) if j != i]))
    tried = []
    for label, frags in ladder:
        sr = trade.search(build_query(q["query"], frags))
        tried.append({"step": label, "listings": sr["total"], "url": sr["url"]})
        need = 3 if label.startswith("all") else a.min_listings
        if sr["total"] >= need:
            ps = trade.fetch_prices(sr, a.listings)
            if not ps:
                continue
            exact = label.startswith("all")
            conf = ("high" if sr["total"] >= 10 else "medium") if exact else "low"
            return dict(chaos=statistics.median(ps), low=ps[0], high=ps[-1], confidence=conf, source="trade",
                        listings=sr["total"], url=sr["url"], keyMods=[m["text"] for m in mods], tried=tried,
                        note=f"variable-mod unique: {label}, median of {len(ps)} cheapest")
    if ninja_row and ninja_row.get("chaos") is not None:
        return {**ninja_row, "confidence": "low", "tried": tried,
                "note": "variable-mod unique: no listings with these mods; poe.ninja base-unique price (likely understated)"}
    return dict(chaos=None, confidence="none", source="trade", tried=tried, note="variable-mod unique: no listings")


def price_base(trade, it, a):
    """Magic items (flasks): people roll them themselves -> price the cheapest normal base."""
    query = {"query": {"status": {"option": "securable"}, "type": it["base"],
                       "filters": {"type_filters": {"filters": {"rarity": {"option": "normal"}}}}},
             "sort": {"price": "asc"}}
    sr = trade.search(query, ttl=6 * 3600)
    if not sr["total"]:
        return dict(chaos=1.0, confidence="medium", source="assumed", note="no normal base listed; assumed 1c")
    ps = trade.fetch_prices(sr, 5, ttl=6 * 3600)
    if not ps:
        return dict(chaos=1.0, confidence="medium", source="assumed", note="base unpriced; assumed 1c")
    return dict(chaos=statistics.median(ps), confidence="high", source="trade", listings=sr["total"],
                url=sr["url"], note="normal base (roll it yourself)")


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--league")
    ap.add_argument("--looseness", type=float, default=0.8)
    ap.add_argument("--listings", type=int, default=10, help="cheapest N listings to take the median of")
    ap.add_argument("--min-listings", type=int, default=10, help="a combo needs this many listings to count as a price")
    ap.add_argument("--max-key", type=int, default=4, help="max key mods to search on")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-trade", action="store_true")
    a = ap.parse_args()

    exp = call("export_build")
    if "error" in exp or "error" in exp.get("result", {}):
        sys.exit(f"bridge: {exp}")
    exp = exp["result"]
    tq = {i["slot"]: i for i in call("trade_queries", looseness=a.looseness)["result"]["items"]}

    league = a.league or current_league()
    ninja = Ninja(league)
    trade = None if a.no_trade else Trade(league, os.environ.get("POE_TRADE_BASE", "https://www.pathofexile.com"),
                                          ninja.chaos_per)
    trade_err = "skipped (--no-trade)" if a.no_trade else None

    rows = []
    for it in exp["items"]:
        row = {"slot": it["slot"], "name": it["name"], "base": it["base"], "rarity": it["rarity"]}
        if it["rarity"] in ("UNIQUE", "RELIC"):
            p = ninja.unique(it)
            q = tq.get(it["slot"])
            if q and q.get("variableUnique") and q["mods"] and trade and not trade_err:
                row["rolledMods"] = [m["text"] for m in q["mods"]]
                if p and p.get("chaos") is not None:
                    row["ninjaChaos"] = p["chaos"]
                try:
                    row.update(price_variable_unique(trade, q, a, p))
                except TradeBlocked as e:
                    trade_err = str(e)
            if "chaos" not in row:
                row.update(p or {"chaos": None, "confidence": "none", "source": "poe.ninja",
                                 "note": "unique not found on poe.ninja"})
                if q and q.get("variableUnique"):
                    row["confidence"] = "low"
                    row["note"] = "variable-mod unique priced at poe.ninja base (trade unavailable)"
        elif it["slot"] in tq:
            q = tq[it["slot"]]
            row["modImpact"] = {m["text"]: m.get("impact", 0) for m in q["mods"]}
            row["unmatchedMods"] = q["unmatched"]
            if trade and not trade_err:
                try:
                    row.update(price_base(trade, it, a) if it["rarity"] == "MAGIC" else price_rare(trade, q, a))
                except TradeBlocked as e:
                    trade_err = str(e)
                except Exception as e:  # keep going on one bad query
                    row.update(chaos=None, confidence="none", source="trade", note=f"error: {e}")
            if "chaos" not in row:
                row.update(chaos=None, confidence="none", source="trade", note=trade_err or "not priced")
        else:
            row.update(chaos=None, confidence="none", source="-", note="normal item / no pricing path")
        rows.append(row)

    gems = []
    for g in exp["gems"]:
        if g.get("source"):
            continue  # granted by an item, not bought
        p = ninja.gem(g) or {"chaos": None, "confidence": "none", "source": "poe.ninja", "note": "gem not on ninja"}
        gems.append({**g, **p})

    priced = [r["chaos"] for r in rows + gems if r.get("chaos") is not None]
    unpriced = [r for r in rows + gems if r.get("chaos") is None]
    total = sum(priced)
    report = {
        "league": league, "divineChaos": ninja.divine, "looseness": a.looseness,
        "totalChaos": round(total, 1), "totalDivine": round(total / ninja.divine, 2),
        "itemsChaos": round(sum(r["chaos"] for r in rows if r.get("chaos") is not None), 1),
        "gemsChaos": round(sum(r["chaos"] for r in gems if r.get("chaos") is not None), 1),
        "unpricedCount": len(unpriced), "tradeStatus": trade_err or "ok",
        "items": rows, "gems": gems,
    }
    if a.json:
        print(json.dumps(report, indent=1))
        return
    dv = ninja.divine
    fmt = lambda c: "   ?   " if c is None else (f"{c/dv:6.2f}d" if c >= dv else f"{c:6.0f}c")
    print(f"Build cost — {league} (1 div = {dv:.0f}c), rares at {int(a.looseness*100)}% of rolls\n")
    for r in sorted(rows, key=lambda r: -(r.get("chaos") or 0)):
        print(f"{fmt(r.get('chaos'))}  {r['slot']:<14} {r['name'][:34]:<34} [{r['confidence']}, {r['source']}] {r.get('note','')}")
    g_total = report["gemsChaos"]
    top = sorted([g for g in gems if g.get("chaos")], key=lambda g: -g["chaos"])[:5]
    print(f"{fmt(g_total)}  Gems ({len(gems)})       top: " + ", ".join(f"{g['name']} {g['chaos']:.0f}c" for g in top))
    print(f"\nTOTAL  {report['totalChaos']:.0f}c = {report['totalDivine']} div   ({len(unpriced)} unpriced; trade: {report['tradeStatus']})")


if __name__ == "__main__":
    main()
