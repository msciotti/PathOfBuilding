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
  { name: "pob_chat_wait", method: "chat_wait",
    description: "Wait for the user to send a message in Path of Building's Agent tab. Blocks up to `timeout` seconds (default 50) and returns the new messages plus the open build's name; on timeout returns timedOut=true, so call it again to keep listening. To serve the in-app chat, loop: pob_chat_wait -> investigate with the other pob_* tools -> pob_chat_reply -> pob_chat_wait.",
    inputSchema: { type: "object", properties: { timeout: int } } },
  { name: "pob_chat_reply", method: "chat_reply",
    description: "Post your answer in Path of Building's Agent tab. Plain text; newlines are kept and long lines wrap. No markdown rendering, so keep lists simple ('- item').",
    inputSchema: { type: "object", properties: { text: str }, required: ["text"] } },
  { name: "pob_chat_status", method: "chat_status",
    description: "Show a short progress line under the Agent tab transcript while you work (e.g. 'Ranking boot mods by chaos max hit...'). Cleared automatically by pob_chat_reply; pass empty text to clear it yourself.",
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
