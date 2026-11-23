// MCP server over the same tools as agent.mjs, for driving PoB from Claude Code (see .mcp.json at the repo root).
// It adds the chat tools, so an MCP client can also answer the Agent panel in place of agent.mjs.
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { rpc, TOOLS as SHARED } from "./tools.mjs";

const str = { type: "string" }, int = { type: "integer" };
const CHAT = [
  { name: "pob_chat_wait", method: "chat_wait",
    description: "Wait for the user to send a message in Path of Building's Agent tab. Blocks up to `timeout` seconds (default 50) and returns the new messages plus the open build's name; on timeout returns timedOut=true, so call it again to keep listening. To serve the in-app chat, loop: pob_chat_wait -> investigate with the other pob_* tools -> pob_chat_reply -> pob_chat_wait. Before replying: test every number you quote with pob_what_if, and test combined recommendations together rather than adding them up; use pob_path_cost for point costs; lead with anything in `alreadyOnBuildIf` (a Config toggle or flask the user already has); check `spawnOn`/`obtain` so you never suggest a mod on a slot it can't roll on.",
    inputSchema: { type: "object", properties: { timeout: int } } },
  { name: "pob_chat_reply", method: "chat_reply",
    description: "Post your answer in Path of Building's Agent tab (it types out in the chat). Plain text; newlines are kept and long lines wrap. No markdown rendering, so keep lists simple ('- item').",
    inputSchema: { type: "object", properties: { text: str }, required: ["text"] } },
  { name: "pob_chat_status", method: "chat_status",
    description: "Show what you're doing, live in the Agent chat transcript (e.g. 'Ranking boot mods by chaos max hit...'). Each call adds a short step under the pending Agent reply; the steps stay as a dim trail above your answer once you pob_chat_reply.",
    inputSchema: { type: "object", properties: { text: str }, required: ["text"] } },
  { name: "pob_chat_history", method: "chat_history",
    description: "Full Agent tab transcript (user and agent messages) for context, e.g. when you connect to a chat already in progress.",
    inputSchema: { type: "object", properties: {} } },
];
const TOOLS = [...SHARED, ...CHAT];

const server = new Server({ name: "pob-agent", version: "0.2.0" }, { capabilities: { tools: {} } });
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
}));
server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const tool = TOOLS.find((t) => t.name === req.params.name);
  if (!tool) return { isError: true, content: [{ type: "text", text: "unknown tool" }] };
  const args = req.params.arguments || {};
  try {
    const r = tool.run ? { result: await tool.run(args) } : await rpc(tool.method, args);
    return { isError: !!r.error, content: [{ type: "text", text: JSON.stringify(r.error ?? r.result) }] };
  } catch (e) {
    return { isError: true, content: [{ type: "text", text: String(e.message) }] };
  }
});
await server.connect(new StdioServerTransport());
