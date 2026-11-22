import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { rpc, TOOLS } from "./tools.mjs";

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
