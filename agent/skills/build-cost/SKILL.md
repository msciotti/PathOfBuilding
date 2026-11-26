---
name: build-cost
description: Use when asked what a Path of Building build costs to buy or swap into. Prices every slot + gem.
---

# Build cost (swap-cost estimate)

Answers "how expensive is it to swap to this build?" for the build open in PoB. Full cost, no stash discount.

## Tools
- `pob_build_cost` — does everything below and returns per-slot prices + totals. Start here.
  `noTrade: true` gives a fast poe.ninja-only estimate (uniques + gems) when trade is slow or blocked.
- `pob_export_build` — equipped items and gems, if you need to reason about a slot yourself.
- `pob_trade_queries` — the trade searches PoB would build for each rare / variable-mod unique, with per-mod
  `impact` scores and query fragments. Use it to price one item by hand or explain a number.
- `pob_variable_uniques` — the uniques that roll from a mod pool.

## Pricing rules (what the tool does, and what to tell the user)
- **Uniques**: poe.ninja, link-aware (5L/6L rows).
- **Variable-mod uniques** (Watcher's Eye, Balance of Terror, Forbidden Flame/Flesh, Megalomaniac, Impossible
  Escape...): poe.ninja's price is the plain item and is wrong. Search real listings of that unique with the
  rolled pool mods: all mods at ~80% rolls → all mods any roll → drop one mod (low confidence) → ninja fallback.
- **Gems**: poe.ninja. Level 18+ is priced as a 20; item-granted gems are skipped.
- **Rares**: price the *key mods*, not the whole item. PoB removes each mod and recalcs; the mods whose loss
  hurts most (DPS, EHP, life, capped resists, unmet attribute requirements weigh 3x) are key. Search the top
  2-4 key mods at 80% of the roll and drop the least important until there are >= 10 listings. A thin market
  (e.g. one 10-div listing) is never a price. Bench crafts are ignored — they're cheap to redo.
- **Cluster jewels**: the notables + exact passive count, nothing else. All notables must match.
- **Magic flasks**: the cheapest normal base. Players roll their own.
- Price = median of the cheapest ~10 instant-buyout listings. Report low/high and the trade link.

## Pitfalls
- GGG's trade API returns 403 to datacenter/VPN IPs. Run PoB + the tool from a home connection.
- Trade rate limits (~5 searches/10s, 600/6h per IP). A cold full build is ~15-30 searches; results are cached
  30 min, so reruns are fast. If the 6h budget is exhausted the tool fails fast instead of sleeping for hours.
- Mods that have no trade-site stat are listed under `unmatchedMods`; say so instead of guessing.
- Not priced yet: anointments (oils), timeless jewels (need a seed search), corrupted implicits on uniques.
- Rares in tree sockets (non-cluster jewels) often show zero measured impact; those fall back to implicit/first
  mods and are low confidence.
