# PoB agent bridge

A personal fork of PathOfBuildingCommunity/PathOfBuilding (PoE1). It lets an agent search the game data PoB has and
evaluate changes with PoB's own calc engine, from a chat panel inside PoB.

## Layout
- `src/AgentData.lua`: one searchable index over item mod pools (including bench mods), passives, mastery effects,
  ascendancies, tattoos, timeless-jewel nodes, uniques, enchants, essences, cluster jewels, item and flask bases,
  pantheon and gems.
- `src/AgentBridge.lua`: line-delimited JSON-RPC on 127.0.0.1:49090, polled from `launch:OnFrame`. `reload` swaps the
  RPC handlers; `restart` (F5, dev mode) reloads all Lua.
- `src/Classes/AgentTab.lua`: the chat panel ("Agent >>" next to Compare).
- `agent/api/agent.mjs`: the chat agent. It runs on the Claude API with the tools defined in `agent/api/tools.mjs`.
- `agent/tools/probe_all.py`: builds the effect index (`agent_effects.json`) on the open build.

Hooks into PoB's own files: `Launch.lua` (start and poll the bridge), `Modules/Build.lua` (panel button and layout),
plus flask Maim/Hinder immunity in `ModParser.lua`/`ModCache.lua`.
Keep these small; they are where upstream merges conflict.

## Bridge methods
`ping, reload, restart, list_sources, search, inspect, get_state, what_if, rank_options, path_cost, parse_mod,
list_stats, probe_batch, find_by_effect, effect_stats, import_character, eval (dev mode), chat_wait, chat_reply,
chat_status, chat_history`. The agent's tools and their parameters are in `agent/api/tools.mjs`.

- `what_if` adds the mods as a temporary Config custom-mod block, recalculates, diffs `calcsTab.mainOutput` and removes
  the block. When a mod's requirements aren't met as configured, `ifConditionsMet` recalculates with them forced on.
- `rank_options` runs `what_if` on every search hit and ranks by a weighted relative change of the goal stats.
- `find_by_effect` uses the effect index: each distinct mod line probed once, keyed by the output stats it moves.
- `chat_wait` holds the connection open until the panel has a message; the agent loop is
  `chat_wait -> tools -> chat_reply`.

## Running
- Run PoB from this tree (`runtime/Path{space}of{space}Building.exe` on Windows) with a build open.
- `cd agent/api && npm install`, put `ANTHROPIC_API_KEY=...` in `agent/api/.env`, then `npm run agent` and chat in the
  Agent panel. `POB_AGENT_MODEL` and `POB_AGENT_EFFORT` are optional.

## Keeping up with upstream
`dev` mirrors upstream; this work lives on `agent-main`.

    git fetch upstream
    git checkout dev && git merge --ff-only upstream/dev && git push origin dev
    git checkout agent-main && git merge dev
