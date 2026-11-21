# PoB agent bridge — handoff notes

Personal patch on PathOfBuildingCommunity/PathOfBuilding v2.68.1 (PoE1). Goal: let an agent browse **everything** PoB knows
(all item-mod pools, passives, uniques, enchants...) and evaluate it with PoB's own calc engine, small and native.

## What's here
- `src/AgentData.lua` — flat searchable index (~32k entries, ~38 sources) built from `data.itemMods`, passive tree, uniques, enchants, essences, gems. Pure data, no UI.
- `src/AgentBridge.lua` — loopback line-delimited JSON-RPC on 127.0.0.1:49090, polled from `launch:OnFrame`. Hot-reloadable (`reload`).
- `src/Launch.lua` — +6 lines: load bridge on init, poll each frame.
- `src/Classes/AgentTab.lua` + `src/Modules/Build.lua` (+9 lines) — in-app **Agent** chat: the "Agent >>" button (next to Compare) toggles a panel docked on the right of whatever tab is open. `ProcessInput` runs before the tab (takes clicks/scroll over the panel, releases focus on outside clicks); `Draw` runs after it on draw sublayer 50 so tree art does not bleed over.
- `agent/mcp/server.mjs` — MCP stdio server proxying to the bridge (`npm install` in `agent/mcp`; env POB_AGENT_PORT). Registered for Claude Code in `/.mcp.json`.
- `agent/tools/` — `rpc.py` (tiny client), `ui.sh` (Xvfb/xdotool screenshot+click driver, Wine), `load_build.sh` (imports a character through the real Import tab), `probe_all.py`, `headless_test.lua`.

## Bridge methods
`ping, reload, restart, list_sources, search{query,sources,slot,limit,exact}, inspect{path,depth,maxKeys}, get_state,
what_if{mods,stats}, rank_options{query,goal,roll,max,top,stats}, probe_batch{budget}, find_by_effect{stat,direction,...}, effect_stats,
chat_wait{timeout}, chat_reply{text}, chat_status{text}, chat_history`.
- Chat (option 1: PoB is only the UI, any external agent connects): the Agent tab queues user messages in `launch.agentChat` (survives `reload`).
  `chat_wait` is *deferred* — the bridge holds the connection open (handler returns `{_defer=fn}`, polled each frame) until a message arrives or the
  timeout (default 50s) passes. Agent loop: `chat_wait -> pob_* tools -> chat_reply -> chat_wait`. Tab shows "listening" while a wait is pending,
  "working" for 2 min after the last chat call. Possible later: option 2, PoB calling the Claude API itself.
- `what_if` adds a temporary Config custom-mod block (`configSets[active].customModsList`), recalcs, diffs `calcsTab.mainOutput`, removes the block.
- `rank_options` = search -> what-if each hit -> rank by weighted relative stat change. Lower tiers of the same mod group are skipped at roll=max.
- `probe_batch`/`find_by_effect` = **effect index** (the "go in reverse" idea): probe each distinct normalised mod line once, cache which output stats it moves
  (`agent_effects.json`, ~10k lines, resumable), then query by outcome stat (e.g. `PoisonAvoidChance` up) instead of matching wording. **Not finished:** ~450/10039 probed.

## Status / caveats
- Verified live in Wine PoB with a real imported build: search, inspect, get_state, what_if, rank_options. `find_by_effect` untested (index incomplete).
- Probing ~2.5 lines/s on a 1GB box (swapping); faster on a real machine. Conditional mods ("while Poisoned") may show zero effect; flag/retry with config flags.
- what_if ignores slot/cost/item-level rules; `spawnOn` from data is the only slot signal.
- Chat tab verified on Windows with a scripted agent (round trip, status line, transcript). Not yet tried with a real agent driving it via MCP.
  Transcript isn't saved with the build and is cleared on restart.
- The bridge holds a suspended coroutine so SimpleGraphic keeps running OnFrame while PoB is unfocused; when the user is idle it blocks in
  `socket.select` (≤250ms) instead of rendering at full rate.
- `LoadModule` caches; `reload` uses `loadfile` relative to PoB's working dir.

## Run it
Windows/Mac/Linux: run PoB from this tree (`runtime/Path{space}of{space}Building.exe` on Windows), build loaded, then `python3 agent/tools/rpc.py ping`.
Chat: `cd agent/mcp && npm install`, start Claude Code in the repo root (approve the `pob-agent` server), ask it to "watch the PoB chat",
then type in PoB's Agent tab.
Linux headless (what I used): `wine`, Xvfb :99, `agent/tools/ui.sh start`, `load_build.sh` (hardcoded account/click coordinates for 1440x900).

- `reload` swaps RPC handlers only; `restart` (= F5, dev mode) reloads all Lua in-process (~3s, unsaved build changes lost). Use it after editing `poll`/`start` or any app code.
