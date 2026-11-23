# PoB agent bridge

A personal fork of PathOfBuildingCommunity/PathOfBuilding (PoE1). It lets an agent search the game data PoB has and
evaluate changes with PoB's own calc engine, from a chat panel inside PoB.

## Layout
- `src/AgentData.lua`: one searchable index over item mod pools (including bench mods), passives, mastery effects,
  ascendancies, tattoos, timeless-jewel nodes, uniques, enchants, essences, cluster jewels, item and flask bases,
  pantheon and gems.
- `src/AgentBridge.lua`: line-delimited JSON-RPC on 127.0.0.1:49090 (`POB_AGENT_PORT` overrides), polled from `launch:OnFrame`. `reload` swaps the
  RPC handlers; `restart` (F5, dev mode) reloads all Lua.
- `src/Classes/AgentTab.lua`: the chat panel ("Agent >>" next to Compare).
- `agent/api/agent.mjs`: the chat agent. It runs on the Claude API with the tools defined in `agent/api/tools.mjs`.
- `agent/api/mcp.mjs`: the same tools plus the `pob_chat_*` tools as an MCP server, for Claude Code (`.mcp.json`).
- `agent/tools/probe_all.py`: builds the effect index (`agent_effects.json`) on the open build. `rpc.py` is a bridge
  client; `sweeps/` and `ailment_sweep.py` check tool results across many mods; `headless_test.lua` loads the bridge
  without the UI; `ui.sh` and `load_build.sh` drive a Wine + Xvfb copy of PoB on Linux (paths are for that machine).

Hooks into PoB's own files: `Launch.lua` (start and poll the bridge), `Modules/Build.lua` (panel button and layout),
plus flask Maim/Hinder immunity in `ModParser.lua`/`ModCache.lua`.
Keep these small; they are where upstream merges conflict.

## Bridge methods
`ping, reload, restart, list_sources, search, inspect, get_state, what_if, gem_what_if, rank_options, path_cost, compare_variants, design_rare, fill_resists, parse_mod,
list_stats, probe_batch, find_by_effect, effect_stats, import_character, optimize_tree, eval (dev mode), chat_wait, chat_reply,
chat_status, chat_history`. The agent's tools and their parameters are in `agent/api/tools.mjs`. Tools with `run` instead of `method` execute in the Node agent (`price_lookup` and `trade_search`, in `market.mjs`) and need no bridge; `pob_fill_resists` is one: it calls the bridge, then prices each item with `trade_search`.

- `what_if` adds the mods as a temporary Config custom-mod block, recalculates, diffs `calcsTab.mainOutput` and removes
  the block. When a mod's requirements aren't met as configured, `ifConditionsMet` recalculates with them forced on.
- `gem_what_if` adds or sets gems in a socket group, recalculates and restores it. A gem without a level gets its `naturalMaxLevel`; levels above it are marked `needsCorruption`.
- `design_rare` builds an item through `Item:Craft` (Prefix/Suffix lines with `{range}`, bench mods as `{crafted}` lines),
  checking each mod with `Item:CanHaveMod` and the item's affix limits, and returns the `BuildRaw` text plus a
  `trade_search`-shaped `tradeQuery`. `fill_resists` measures the resist gaps with the bare bases equipped,
  picks implicit variants and resist mods across the slots, spends the rest, and evaluates the result with the same `variantRow` as `compare_variants`.
- `rank_options` runs `what_if` on every search hit and ranks by a weighted relative change of the goal stats.
- `find_by_effect` uses the effect index: each distinct mod line probed once, keyed by the output stats it moves.
- `chat_wait` holds the connection open until the panel has a message; the agent loop is
  `chat_wait -> tools -> chat_reply`.

## Running
- Run PoB from this tree (`runtime/Path{space}of{space}Building.exe` on Windows) with a build open. On macOS, build
  the runtime from the `main` branch of msciotti/PathOfBuilding-SimpleGraphic (`macos/README.md` there) and run
  `runtime/PathOfBuilding`.
- `cd agent/api && npm install`, put `ANTHROPIC_API_KEY=...` in `agent/api/.env`, then `npm run agent` and chat in the
  Agent panel. `POB_AGENT_MODEL` and `POB_AGENT_EFFORT` are optional.
- Or, from Claude Code in this tree: after `npm install` in `agent/api`, the `pob-agent` MCP server in `.mcp.json` gives
  Claude the `pob_*` tools. To answer the Agent panel from Claude Code, loop `pob_chat_wait -> tools -> pob_chat_reply`.

## Branches and keeping up with upstream
- `dev` mirrors upstream/dev. Never commit to it.
- `main` is the daily driver (the fork's default branch): upstream plus this work. Upstream comes in by merge, never
  rebase, and `main` is never force-pushed, so every machine just pulls.
- Work branches come off `main` and merge back into it. Fixes meant for PathOfBuildingCommunity come off `dev`.

    git fetch upstream
    git checkout dev && git merge --ff-only upstream/dev && git push origin dev
    git checkout main && git merge dev && git push origin main
