# PoB agent bridge — handoff notes

Personal patch on PathOfBuildingCommunity/PathOfBuilding v2.68.1 (PoE1). Goal: let an agent browse **everything** PoB knows
(all item-mod pools, passives, uniques, enchants...) and evaluate it with PoB's own calc engine, small and native.

## What's here
- `src/AgentData.lua` — flat searchable index (~32k entries, ~38 sources) built from `data.itemMods`, passive tree, uniques, enchants, essences, gems. Pure data, no UI.
- `src/AgentBridge.lua` — loopback line-delimited JSON-RPC on 127.0.0.1:49090, polled from `launch:OnFrame`. Hot-reloadable (`reload`).
- `src/Launch.lua` — +6 lines: load bridge on init, poll each frame. Only edit to upstream.
- `agent/mcp/server.mjs` — MCP stdio server proxying to the bridge (needs `@modelcontextprotocol/sdk`; env POB_AGENT_PORT).
- `agent/tools/` — `rpc.py` (tiny client), `ui.sh` (Xvfb/xdotool screenshot+click driver, Wine), `load_build.sh` (imports a character through the real Import tab), `probe_all.py`, `headless_test.lua`.

## Bridge methods
`ping, reload, list_sources, search{query,sources,slot,limit,exact}, inspect{path,depth,maxKeys}, get_state,
what_if{mods,stats}, rank_options{query,goal,roll,max,top,stats}, probe_batch{budget}, find_by_effect{stat,direction,...}, effect_stats`.
- `what_if` adds a temporary Config custom-mod block (`configSets[active].customModsList`), recalcs, diffs `calcsTab.mainOutput`, removes the block.
- `rank_options` = search -> what-if each hit -> rank by weighted relative stat change. Lower tiers of the same mod group are skipped at roll=max.
- `probe_batch`/`find_by_effect` = **effect index** (the "go in reverse" idea): probe each distinct normalised mod line once, cache which output stats it moves
  (`agent_effects.json`, ~10k lines, resumable), then query by outcome stat (e.g. `PoisonAvoidChance` up) instead of matching wording. **Not finished:** ~450/10039 probed.

## Status / caveats
- Verified live in Wine PoB with a real imported build: search, inspect, get_state, what_if, rank_options. `find_by_effect` untested (index incomplete).
- Probing ~2.5 lines/s on a 1GB box (swapping); faster on a real machine. Conditional mods ("while Poisoned") may show zero effect; flag/retry with config flags.
- what_if ignores slot/cost/item-level rules; `spawnOn` from data is the only slot signal.
- Not done: in-app chat tab (plan: `Classes/AgentTab.lua` modelled on NotesTab + `launch:DownloadPage` to a local agent), wiring Hermes (deliberately kept local to PoB).
- `LoadModule` caches; `reload` uses `loadfile` relative to PoB's working dir.

## Run it
Windows/Mac/Linux: run PoB from this tree (`src/`), build loaded, then `python3 agent/tools/rpc.py ping`.
Linux headless (what I used): `wine`, Xvfb :99, `agent/tools/ui.sh start`, `load_build.sh` (hardcoded account/click coordinates for 1440x900).
