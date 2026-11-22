# PoB agent bridge — handoff notes

Personal patch on PathOfBuildingCommunity/PathOfBuilding v2.68.1 (PoE1). Goal: let an agent browse **everything** PoB knows
(all item-mod pools, passives, uniques, enchants...) and evaluate it with PoB's own calc engine, small and native.

## What's here
- `src/AgentData.lua` — flat searchable index built from: item mod pools (`mod:*`, incl. `mod:Crafted` bench mods), passives
  (`passive:normal/notable/keystone`, `passive:mastery` effects, `passive:ascendancy:<Name>`), tattoos, timeless-jewel nodes, uniques
  (legacy "Pre x.y" variant lines dropped, wrapped lines rejoined), enchants (helmet per-skill tiers, weapon enchants once with eligible
  types), essences (mod ids resolved to text + `essenceSlots`), item/flask bases (`base:<type>` implicits and flask buffs), pantheon, gems.
  Search ranks by relevance (whole query in one line > all terms in one line > shorter entry; minion/"in your Presence" lines sink), requires
  all terms within one line (or the name), short terms must start a word, and expands synonyms (`SYN`: ms, es, res, dps, pen, cdr, regen...).
  Pure data, no UI.
- `src/AgentBridge.lua` — loopback line-delimited JSON-RPC on 127.0.0.1:49090, polled from `launch:OnFrame`. Hot-reloadable (`reload`).
- `src/Launch.lua` — +6 lines: load bridge on init, poll each frame.
- `src/Classes/AgentTab.lua` + `src/Modules/Build.lua` (+9 lines) — in-app **Agent** chat: the "Agent >>" button (next to Compare) toggles a panel docked on the right of whatever tab is open. `ProcessInput` runs before the tab (takes clicks/scroll over the panel, releases focus on outside clicks); `Draw` runs after it on draw sublayer 50 so tree art does not bleed over.
- `agent/mcp/server.mjs` — MCP stdio server proxying to the bridge (`npm install` in `agent/mcp`; env POB_AGENT_PORT). Registered for Claude Code in `/.mcp.json`.
- `agent/tools/` — `rpc.py` (tiny client), `ui.sh` (Xvfb/xdotool screenshot+click driver, Wine), `load_build.sh` (imports a character through the real Import tab), `probe_all.py`, `headless_test.lua`.

## Bridge methods
`ping, reload, restart, list_sources, search{query,sources,slot,limit,exact,includeLegacy}, inspect{path,depth,maxKeys}, get_state,
what_if{mods,stats,roll,assume,slot}, rank_options{query,goal,roll,max,top,stats,assume,includeLegacy}, path_cost{nodes}, parse_mod{lines,roll}, list_stats{query},
probe_batch{budget,reset}, find_by_effect{stat,direction,conditional,...}, effect_stats,
chat_wait{timeout}, chat_reply{text}, chat_status{text}, chat_history`.
- Chat (option 1: PoB is only the UI, any external agent connects): the Agent tab queues user messages in `launch.agentChat` (survives `reload`).
  `chat_wait` is *deferred* — the bridge holds the connection open (handler returns `{_defer=fn}`, polled each frame) until a message arrives or the
  timeout (default 50s) passes. Agent loop: `chat_wait -> pob_* tools -> chat_reply -> chat_wait`. Tab shows "listening" while a wait is pending,
  "working" for 2 min after the last chat call. Possible later: option 2, PoB calling the Claude API itself.
- `what_if` adds a temporary Config custom-mod block (`configSets[active].customModsList`), recalcs, diffs `calcsTab.mainOutput`, removes the block.
  Requirements come from the parsed mod tags (`requirements()`), each with `metOnBuild`; when any isn't met, `ifConditionsMet` recalcs with
  them forced: Condition -> `Condition:X` flag; "not X" -> config mods named `Condition:X` removed; MultiplierThreshold -> base multiplier;
  "per <X> Charge" -> charges at max; flask "during Effect"/Flask* mods -> equipped flask slots temporarily set active. Forced mods are added
  to `configTab.modList` after `BuildModList()` (CalcSetup adds that list to the modDB). ItemCondition/StatThreshold/actor conditions are
  reported only. Socketed-gem lines (`SocketedIn {SlotName}`) are added as raw mods bound to `slot` (default: main skill's socket slot).
  Also returns `modTotals` (modDB sums for the parsed mod names, for effects with no output stat), `capped`, `changedOther` (moved outside
  the `stats` filter), and notes for allocated keystones, attack-only mods on spell builds, and Hit-context buffs. inf/nan are sent as strings.
- `rank_options` = search -> what-if each hit -> rank by weighted (after-before)/max(|before|,|after|) (bounded, works when before=0).
  Conditional rows are re-scored with conditions forced (`assumed`); rows show `requires` and `unsupported` lines; zero-score rows are dropped
  (`noEffect`). Uniques score only their query-matching lines. Lower tiers of the same mod group are skipped at roll=max.
  Conditional rows are measured against the build with the same assumptions applied (so switching on an equipped flask isn't credited
  to the tested mod); assumptions that reach the goal by themselves are listed in `alreadyOnBuildIf`, and identical text from other
  sources in `alsoFrom`. Passives/mastery effects already allocated are skipped (`alreadyAllocated`); passive rows carry `pathDist`.
- Index labels: explicit/corrupted mods with zero spawn weight carry `obtain` (essence only, Maven's Orb for Elevated, special source);
  ones whose item tags all weigh 0 are `legacy` and hidden unless `includeLegacy`. Cluster jewels are `cluster:enchant` (small passive
  stats) and `cluster:notable`/`cluster:keystone` (`spawnOn` = enchants they roll with, mapped by enchant tag). Derived stats
  `<Ailment>ImmuneEffective` cover both "Cannot be X" and "Unaffected by X".
- `path_cost{nodes}` = points to allocate several nodes together (ids or names), 0-1 BFS with PoB's pathing rules, greedy over targets.
- `what_if` `ifConditionsMet.alreadyFromAssumptions`: the assumptions alone already give the effect (e.g. a flask the build has).
- `parse_mod` shows PoB's parsed mods incl. tags and decoded `flags`/`keywordFlags` (Hit, Dot, Attack...), `supported`, `requires`.
- `get_state` includes `mainSkill` {name, skill types} and a `dpsHint` (use CombinedDPS; FullDPS needs skills in Full DPS).
- `probe_batch`/`find_by_effect` = **effect index** (the "go in reverse" idea): probe each distinct normalised mod line once, cache which output stats it moves
  (`agent_effects.json`, ~10k lines, resumable, gitignored), then query by outcome stat (e.g. `PoisonAvoidChance` up) instead of matching wording.
  Each line stores the plain delta and the delta with requirements forced (`dm`); hits carry `requires` and `requirementsMetOnBuild`.
  Built on the Gladiator test build: 10036 probed, 2776 unsupported by PoB's parser, 1114 conditional (~48 lines/s). Rebuild with
  `agent/tools/probe_all.py --reset` for a different build; new index entries are picked up by running it without `--reset`.

## Sweeps (regression tests, need PoB running with a build loaded)
`agent/tools/ailment_sweep.py` (18 ailment/immunity cases), `agent/tools/sweeps/{defence,offence,utility}_sweep.py`; `--verbose` for detail.
Each case uses a real game-data line found by search and checks the stat moves (directly, or via `ifConditionsMet` for conditional lines).

## Parser additions
- ModParser + ModCache: flask "Grants Immunity to Maim/Hinder for N seconds if used while Maimed/Hindered" -> `MaimImmune`/`HinderImmune`
  with `Condition:UsingFlask` (ModCache entries updated by hand; regenerate with REGENERATE_MOD_CACHE=1 to be sure).

## Status / caveats
- Known gaps: exposure-on-hit mods only flip a Config checkbox (not forced yet); most charge/buff *generation* lines are unsupported by PoB
  (it uses Config toggles); "if Hit an Enemy Recently" wording is unsupported while "if you've Hit..." parses; no max-resistance output stat
  (use XResistOverCap); weapon/unique "Rarity: UNIQUE" generated entries are named by base.
- Conditional mods ("while Poisoned") are evaluated with their conditions forced; tell the user when an answer depends on `assumed`.
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
