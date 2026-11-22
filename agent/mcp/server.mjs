import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import net from "node:net";

const PORT = Number(process.env.POB_AGENT_PORT || 49090);

function rpc(method, params = {}) {
  return new Promise((resolve, reject) => {
    const s = net.createConnection({ host: "127.0.0.1", port: PORT });
    let buf = "";
    const t = setTimeout(() => { s.destroy(); reject(new Error("PoB bridge timeout")); }, 300000);
    s.on("connect", () => s.write(JSON.stringify({ id: 1, method, params }) + "\n"));
    s.on("data", (d) => { buf += d; if (buf.endsWith("\n")) { clearTimeout(t); s.end(); try { resolve(JSON.parse(buf)); } catch (e) { reject(e); } } });
    s.on("error", (e) => { clearTimeout(t); reject(new Error("Cannot reach PoB bridge (is Path of Building running?): " + e.message)); });
  });
}

const str = { type: "string" }, int = { type: "integer" }, strs = { type: "array", items: str };
const TOOLS = [
  { name: "pob_list_sources", method: "list_sources",
    description: "List every game-data source in the open Path of Building (item mod pools like Eldritch/Flask/Corrupted, passive tree nodes, uniques, enchants, essences, gems) with entry counts. Call first to learn the universe of options.",
    inputSchema: { type: "object", properties: {} } },
  { name: "pob_search", method: "search",
    description: "Search ALL PoB game data at once. Terms are ANDed; some words expand ('immune' also matches 'cannot be', 'unaffected by'). Returns hits labelled by source with eligible item slots (spawnOn) plus a per-source breakdown so you can see every path (nodes, flask suffixes, boot mods, eldritch implicits, uniques...). Results are ranked by relevance (whole query in one line first; minion and 'in your Presence' lines sink unless asked for). Short terms like 'es'/'ms'/'res' expand to their full words. Sources include item mod pools (mod:Explicit, mod:Crafted bench mods, mod:Flask...), passive:normal/notable/keystone/mastery, passive:ascendancy:<Name>, tattoo, timeless, unique:<type>, enchant:<slot>, essence (with essenceSlots), base:<type> implicits/flask buffs, pantheon:major/minor, gem. Narrow with `sources` prefixes (e.g. ['mod:Flask','passive']) and `slot`.",
    inputSchema: { type: "object", properties: { query: str, sources: strs, slot: str, limit: int, exact: { type: "boolean" } }, required: ["query"] } },
  { name: "pob_inspect", method: "inspect",
    description: "Read-only walk of any live PoB Lua table by dotted path. Roots: build, data, main, tree. e.g. 'build.calcsTab.mainOutput.Life', 'build.spec.allocNodes', 'build.itemsTab.items.1', 'data.skills'. Output is depth/size bounded; raise `depth`/`maxKeys` to go deeper.",
    inputSchema: { type: "object", properties: { path: str, depth: int, maxKeys: int }, required: ["path"] } },
  { name: "pob_get_state", method: "get_state",
    description: "Current build: class, ascendancy, level, main skill (name and skill types, e.g. Spell vs Attack - explains why attack-only mods do nothing) and the full calculated stat output (hundreds of keys: Life, TotalDPS, resists, avoid chances...).",
    inputSchema: { type: "object", properties: {} } },
  { name: "pob_rank_options", method: "rank_options",
    description: "Find AND rank every way to get something. Runs a pob_search query, evaluates each hit as a what-if on the open build via PoB's calc engine, and ranks by `goal` (a stat name like 'TotalDPS', or weights {Life:1, ChaosMaxHit:0.5}); score = weighted (after-before)/max(|before|,|after|), so -1..1 per stat. Rows that don't move the goal are dropped (counted in noEffect); identical mod text from several sources is scored once and the other sources are listed in `alsoFrom` (e.g. a unique's line that also exists as a vestigial implicit). `alreadyOnBuildIf` lists assumptions that reach the goal by themselves (e.g. switching on an equipped flask) - mention those first. For ailment immunity use goal '<Ailment>ImmuneEffective' (covers both 'Cannot be X' and 'Unaffected by X'). rows whose lines PoB can't parse list them in `unsupported`. Ranges resolve to `roll` (max|mid|min). Mixes sources (nodes, flask mods, eldritch, uniques...) so you can compare paths. Conditional sources are scored with their conditions forced on and carry `assumed` (say so to the user); unconditional ones sort first on ties. Long uniques are scored on their query-matching lines only (`matchedLinesOnly`). Check `spawnOn`/source for slot feasibility; evaluation ignores slot/cost. `max` caps candidates evaluated (default 500; lower tiers of the same mod group are skipped when roll=max; PoB UI blocks while it runs), results include per-stat before/after.",
    inputSchema: { type: "object", properties: { query: str, sources: strs, slot: str, goal: { oneOf: [str, { type: "object", additionalProperties: { type: "number" } }] }, roll: { type: "string", enum: ["max", "mid", "min"] }, max: int, top: int, stats: strs, exact: { type: "boolean" }, assume: { type: "boolean" } }, required: ["query"] } },
  { name: "pob_what_if", method: "what_if",
    description: "Evaluate hypothetical mod text on the open build using PoB's own calc engine, without changing the build. Pass mod lines as they appear in game (e.g. 'Cannot be Poisoned', '+50 to maximum Life'); '(a-b)' ranges resolve to `roll`. Returns `changed` (before/after of every stat that moved), `current` (values of the `stats` you asked for, even if unchanged - use this to see the build already has something), `unsupported` (lines PoB's parser ignores: PoB does not model them at all), `requires` (conditions/thresholds the mod needs) and, for conditional mods (flask 'during Effect', 'while affected by <aura>', 'at 25 Rage'...), `ifConditionsMet`: the effect with those requirements forced on, listing what was `assumed`. Always tell the user when an answer depends on an assumed condition. Each requirement has metOnBuild (already true as configured). 'not X' conditions are assumed by clearing X; 'per Frenzy Charge' etc. are assumed at max charges; flask 'during Effect' activates the equipped flasks. Socketed-gem lines ('+1 to Level of Socketed Gems', 'Socketed Gems are Supported by...') apply to `slot` (default: the main skill's slot; see socketedAppliedTo). Also returns `modTotals` (summed mod values, for effects no output stat shows like flask duration), `capped` (stat already at its cap, only OverCap moved) and `changedOther` (stats that moved outside your `stats` filter).",
    inputSchema: { type: "object", properties: { mods: strs, stats: strs, roll: { type: "string", enum: ["max", "mid", "min"] }, assume: { type: "boolean" }, slot: str }, required: ["mods"] } },
  { name: "pob_find_by_effect", method: "find_by_effect",
    description: "Reverse lookup: every game-data entry (item mods, nodes, uniques, flask mods...) whose mod lines move an output `stat` (e.g. 'FreezeAvoidChance', 'ChaosMaxHit', 'TotalDPS') in `direction` up|down on the open build, ranked by size. Finds things regardless of wording. Uses a precomputed effect index for the build it was built on; hits with `requires` only apply once those conditions hold (pass conditional=false to exclude). Use pob_list_stats to find stat names.",
    inputSchema: { type: "object", properties: { stat: str, direction: { type: "string", enum: ["up", "down"] }, min: { type: "number" }, sources: strs, slot: str, limit: int, conditional: { type: "boolean" } }, required: ["stat"] } },
  { name: "pob_parse_mod", method: "parse_mod",
    description: "Show how PoB's mod parser reads mod lines: the internal mods produced (name/type/value/tags, plus flags/keywordFlags such as Hit or Dot that restrict where a mod applies), whether the line is supported at all (supported=false means PoB ignores it), and what it `requires` (conditions, thresholds). Use to explain why a mod has no effect, or to check exact wording.",
    inputSchema: { type: "object", properties: { lines: strs, roll: { type: "string", enum: ["max", "mid", "min"] } }, required: ["lines"] } },
  { name: "pob_list_stats", method: "list_stats",
    description: "List PoB's calculated output stat names for the open build with current values (and the sidebar label where one exists). Filter with `query` (e.g. 'avoid', 'maxhit', 'resist', 'dps'). Use these names as goals/stats in other tools.",
    inputSchema: { type: "object", properties: { query: str } } },
  { name: "pob_chat_wait", method: "chat_wait",
    description: "Wait for the user to send a message in Path of Building's Agent tab. Blocks up to `timeout` seconds (default 50) and returns the new messages plus the open build's name; on timeout returns timedOut=true, so call it again to keep listening. To serve the in-app chat, loop: pob_chat_wait -> investigate with the other pob_* tools -> pob_chat_reply -> pob_chat_wait.",
    inputSchema: { type: "object", properties: { timeout: int } } },
  { name: "pob_chat_reply", method: "chat_reply",
    description: "Post your answer in Path of Building's Agent tab (it types out in the chat). Plain text; newlines are kept and long lines wrap. No markdown rendering, so keep lists simple ('- item').",
    inputSchema: { type: "object", properties: { text: str }, required: ["text"] } },
  { name: "pob_chat_status", method: "chat_status",
    description: "Show what you're doing, live in the Agent chat transcript (e.g. 'Ranking boot mods by chaos max hit...'). Each call adds a short step under the pending Agent reply, so call it as you move between investigation steps; the steps stay as a dim trail above your answer once you pob_chat_reply.",
    inputSchema: { type: "object", properties: { text: str }, required: ["text"] } },
  { name: "pob_chat_history", method: "chat_history",
    description: "Full Agent tab transcript (user and agent messages) for context, e.g. when you connect to a chat already in progress.",
    inputSchema: { type: "object", properties: {} } },
];

const server = new Server({ name: "pob-agent", version: "0.1.0" }, { capabilities: { tools: {} } });
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
}));
server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const tool = TOOLS.find((t) => t.name === req.params.name);
  if (!tool) return { isError: true, content: [{ type: "text", text: "unknown tool" }] };
  try {
    const r = await rpc(tool.method, req.params.arguments || {});
    return { isError: !!r.error, content: [{ type: "text", text: JSON.stringify(r.error ?? r.result) }] };
  } catch (e) {
    return { isError: true, content: [{ type: "text", text: String(e.message) }] };
  }
});
await server.connect(new StdioServerTransport());
