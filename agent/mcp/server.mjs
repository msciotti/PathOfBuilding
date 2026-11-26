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
    description: "Search ALL PoB game data at once. Terms are ANDed; some words expand ('immune' also matches 'cannot be', 'unaffected by'). Returns hits labelled by source with eligible item slots (spawnOn) plus a per-source breakdown so you can see every path (nodes, flask suffixes, boot mods, eldritch implicits, uniques...). Narrow with `sources` prefixes (e.g. ['mod:Flask','passive']) and `slot`.",
    inputSchema: { type: "object", properties: { query: str, sources: strs, slot: str, limit: int, exact: { type: "boolean" } }, required: ["query"] } },
  { name: "pob_inspect", method: "inspect",
    description: "Read-only walk of any live PoB Lua table by dotted path. Roots: build, data, main, tree. e.g. 'build.calcsTab.mainOutput.Life', 'build.spec.allocNodes', 'build.itemsTab.items.1', 'data.skills'. Output is depth/size bounded; raise `depth`/`maxKeys` to go deeper.",
    inputSchema: { type: "object", properties: { path: str, depth: int, maxKeys: int }, required: ["path"] } },
  { name: "pob_get_state", method: "get_state",
    description: "Current build: class, ascendancy, level and the full calculated stat output (hundreds of keys: Life, TotalDPS, resists, avoid chances...).",
    inputSchema: { type: "object", properties: {} } },
  { name: "pob_rank_options", method: "rank_options",
    description: "Find AND rank every way to get something. Runs a pob_search query, evaluates each hit as a what-if on the open build via PoB's calc engine, and ranks by `goal` (a stat name like 'TotalDPS', or weights {Life:1, ChaosMaxHitTaken:0.5}); score = weighted relative change. Ranges resolve to `roll` (max|mid|min). Mixes sources (nodes, flask mods, eldritch, uniques...) so you can compare paths. Check `spawnOn`/source for slot feasibility; evaluation ignores slot/cost. `max` caps candidates evaluated (default 500; lower tiers of the same mod group are skipped when roll=max; ~0.25s each and PoB UI blocks while it runs), results include per-stat before/after.",
    inputSchema: { type: "object", properties: { query: str, sources: strs, slot: str, goal: { oneOf: [str, { type: "object", additionalProperties: { type: "number" } }] }, roll: { type: "string", enum: ["max", "mid", "min"] }, max: int, top: int, stats: strs, exact: { type: "boolean" } }, required: ["query"] } },
  { name: "pob_what_if", method: "what_if",
    description: "Evaluate hypothetical mod text on the open build using PoB's own calc engine, without changing the build. Pass mod lines as they appear in game (e.g. 'Cannot be Poisoned', '+50 to maximum Life'); returns before/after for every stat that changed. Optionally filter with `stats`.",
    inputSchema: { type: "object", properties: { mods: strs, stats: strs }, required: ["mods"] } },
  { name: "pob_export_build", method: "export_build",
    description: "Equipped items (slot, rarity, base, links, raw text) and socketed gems (level, quality, corrupted, item-granted) of the open build. Use before reasoning about gear or swap cost.",
    inputSchema: { type: "object", properties: {} } },
  { name: "pob_trade_queries", method: "trade_queries",
    description: "Official-trade-site search queries for each equipped rare/magic item and each variable-mod unique (Watcher's Eye, Balance of Terror...), built with PoB's own Buy-Similar matcher. Each mod carries a per-mod query fragment and an `impact` score = how much the build loses (DPS/EHP/life/resists/attributes) if that mod is removed; use the high-impact mods as the 'key mods' to search on. Bench crafts are excluded. Mins = roll x `looseness` (0.8).",
    inputSchema: { type: "object", properties: { looseness: { type: "number" }, maxMods: int, slots: strs, impact: { type: "boolean" } } } },
  { name: "pob_variable_uniques", method: "variable_uniques",
    description: "List uniques in PoB's database whose mods are rolled from a pool (so poe.ninja's single price is wrong for them and real listings with the rolled mods must be priced).",
    inputSchema: { type: "object", properties: {} } },
];

// build_cost runs outside PoB (network pricing), so it's a local subprocess rather than a bridge method.
import { execFile } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
const BUILD_COST = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "tools", "build_cost.py");
TOOLS.push({ name: "pob_build_cost", local: true,
  description: "Estimate what it costs to BUY the build open in Path of Building (swap cost). Uniques + gems from poe.ninja; variable-mod uniques, rares and cluster jewels from real trade listings (rares on their highest-impact mods, needing a real market of >= minListings); magic flasks at normal-base price. Returns per-slot chaos price, low/high, confidence, source, trade URL and the mods searched, plus totals in chaos and divine. Trade calls need a residential IP (GGG blocks datacenters); ~2-5 min on a cold cache due to rate limits. noTrade=true for a fast ninja-only estimate.",
  inputSchema: { type: "object", properties: { league: str, looseness: { type: "number" }, listings: int, minListings: int, maxKey: int, noTrade: { type: "boolean" } } } });
function runBuildCost(a) {
  const args = [BUILD_COST, "--json"];
  if (a.league) args.push("--league", a.league);
  if (a.looseness) args.push("--looseness", String(a.looseness));
  if (a.listings) args.push("--listings", String(a.listings));
  if (a.minListings) args.push("--min-listings", String(a.minListings));
  if (a.maxKey) args.push("--max-key", String(a.maxKey));
  if (a.noTrade) args.push("--no-trade");
  return new Promise((resolve) => execFile("python3", args, { timeout: 600000, maxBuffer: 1 << 24 }, (err, out, errOut) =>
    resolve(err ? { error: String(errOut || err.message) } : { result: JSON.parse(out) })));
}

const server = new Server({ name: "pob-agent", version: "0.1.0" }, { capabilities: { tools: {} } });
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
}));
server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const tool = TOOLS.find((t) => t.name === req.params.name);
  if (!tool) return { isError: true, content: [{ type: "text", text: "unknown tool" }] };
  try {
    const r = tool.local ? await runBuildCost(req.params.arguments || {}) : await rpc(tool.method, req.params.arguments || {});
    return { isError: !!r.error, content: [{ type: "text", text: JSON.stringify(r.error ?? r.result) }] };
  } catch (e) {
    return { isError: true, content: [{ type: "text", text: String(e.message) }] };
  }
});
await server.connect(new StdioServerTransport());
