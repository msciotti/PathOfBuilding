// Agent for Path of Building's Agent tab: answers chat messages through the Claude API using the PoB bridge tools.
//   ANTHROPIC_API_KEY=sk-ant-... node agent.mjs      (or put the key in agent/api/.env and run `npm run agent`)
// Optional: POB_AGENT_MODEL (default claude-opus-5-5), POB_AGENT_EFFORT (low|medium|high|xhigh|max, default high).
import Anthropic from "@anthropic-ai/sdk";
import AjvModule from "ajv";
import { rpc, TOOLS } from "./tools.mjs";

const MODEL = process.env.POB_AGENT_MODEL || "claude-opus-5-5";
const EFFORT = process.env.POB_AGENT_EFFORT || "high";
const MAX_RESULT_CHARS = 100000;
// Server-side refusal fallback ("default" routes by refusal category); only these models accept it
const FALLBACK_MODELS = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"];

const SYSTEM = `You are the build assistant inside Path of Building (PoB) for Path of Exile 1. The user chats with you from PoB's Agent tab about the build they have open, and your tools read PoB's game data and run its calc engine on that build.

How to answer:
- Ground every claim in the tools. Test every number you quote with pob_what_if, and test combined recommendations together rather than adding them up.
- Use pob_path_cost for passive point costs; never estimate them.
- Lead with anything in alreadyOnBuildIf (a Config toggle or flask the user already has).
- Check spawnOn/obtain so you never suggest a mod on a slot it can't roll on, and never suggest legacy mods.
- When a result depends on an assumed condition (ifConditionsMet / assumed), say so.
- If the user corrects you, re-check with the tools before agreeing.

Your final message is shown in PoB's chat panel as plain text: no markdown rendering (no headers, bold or tables). Keep lists simple ('- item'), keep it concise, and give concrete numbers before/after.`;

const Ajv = AjvModule.default ?? AjvModule;
const ajv = new Ajv({ strict: false, allErrors: true });
const validators = Object.fromEntries(TOOLS.map((t) => [t.name, ajv.compile(t.inputSchema)]));

const tools = TOOLS.map((t) => ({
  name: t.name,
  description: t.description,
  input_schema: t.inputSchema,
  eager_input_streaming: true,
}));

const client = new Anthropic();
const betas = ["context-management-2025-06-27", "thinking-display-updates-2026-08-18"];
const useFallbacks = FALLBACK_MODELS.includes(MODEL);
if (useFallbacks) betas.push("server-side-fallback-2026-07-01");

let messages = [];

const status = (text) => rpc("chat_status", { text }).catch(() => {});
const reply = (text) => rpc("chat_reply", { text });

function toolLabel(name, input) {
  const what = input.query ?? input.stat ?? input.path ?? (input.mods || input.lines || input.nodes || []).join("; ");
  return `${name.replace(/^pob_/, "")}${what ? `: ${String(what).slice(0, 80)}` : ""}`;
}

async function runTool(block) {
  const tool = TOOLS.find((t) => t.name === block.name);
  if (!tool) return { content: `unknown tool ${block.name}`, is_error: true };
  // Eager input streaming skips the API's validation, so check the input here
  if (!validators[block.name](block.input)) {
    return { content: `Invalid input ${JSON.stringify(block.input)}: ${ajv.errorsText(validators[block.name].errors)}`, is_error: true };
  }
  try {
    const r = await rpc(tool.method, block.input);
    let text = JSON.stringify(r.error ?? r.result);
    if (text.length > MAX_RESULT_CHARS) {
      text = text.slice(0, MAX_RESULT_CHARS) + `\n[truncated: result was ${text.length} chars; narrow the query or lower limit/depth]`;
    }
    return { content: text, is_error: !!r.error };
  } catch (e) {
    return { content: String(e.message), is_error: true };
  }
}

async function answer() {
  for (;;) {
    const stream = client.beta.messages.stream({
      model: MODEL,
      max_tokens: 64000,
      betas,
      system: SYSTEM,
      tools,
      messages,
      thinking: { type: "adaptive", display: "updates" },
      output_config: { effort: EFFORT },
      cache_control: { type: "ephemeral" },
      // Old tool results are cleared server-side as the conversation grows; the history sent stays append-only
      context_management: { edits: [{ type: "clear_tool_uses_20250919" }] },
      ...(useFallbacks ? { fallbacks: "default" } : {}),
    });
    stream.on("contentBlock", (block) => {
      if (block.type === "thinking" && block.thinking?.trim()) status(block.thinking.trim());
    });
    let msg;
    try {
      msg = await stream.finalMessage();
    } catch (e) {
      if (e instanceof Anthropic.APIError) throw e;
      // Tool input JSON the SDK couldn't parse: no tool_use block to answer, so just ask again
      console.error("unparseable tool input, retrying:", e.message);
      continue;
    }
    messages.push({ role: "assistant", content: msg.content });
    const text = msg.content.filter((b) => b.type === "text").map((b) => b.text).join("\n").trim();

    if (msg.stop_reason === "refusal") {
      return text || "Sorry, I can't help with that request.";
    }
    if (msg.stop_reason === "pause_turn") continue;
    const uses = msg.content.filter((b) => b.type === "tool_use");
    if (msg.stop_reason === "max_tokens") {
      if (uses.length) {
        // A tool call cut off mid-input: answer it as an error so the history stays valid
        messages.push({ role: "user", content: uses.map((u) => ({ type: "tool_result", tool_use_id: u.id, content: "Cut off at max_tokens; not run.", is_error: true })) });
      }
      return (text ? text + "\n\n" : "") + "[reply cut off: hit the output limit]";
    }
    if (msg.stop_reason !== "tool_use" || !uses.length) return text || "(no reply)";

    for (const u of uses) if (!msg.content.some((b) => b.type === "thinking" && b.thinking?.trim())) status(toolLabel(u.name, u.input));
    const results = await Promise.all(uses.map(async (u) => ({ type: "tool_result", tool_use_id: u.id, ...(await runTool(u)) })));
    messages.push({ role: "user", content: results });
  }
}

function errorText(e) {
  if (e instanceof Anthropic.AuthenticationError) return "Agent error: the API key was rejected. Check ANTHROPIC_API_KEY.";
  if (e instanceof Anthropic.PermissionDeniedError) return `Agent error: the API key can't use ${MODEL}.`;
  if (e instanceof Anthropic.RateLimitError) return "Agent error: rate limited by the API. Try again in a minute.";
  if (e instanceof Anthropic.APIConnectionError) return "Agent error: couldn't reach the Claude API.";
  if (e instanceof Anthropic.APIError) return `Agent error: API returned ${e.status}: ${e.message}`;
  return `Agent error: ${e.message}`;
}

async function main() {
  if (!process.env.ANTHROPIC_API_KEY && !process.env.ANTHROPIC_AUTH_TOKEN) {
    console.error("Set ANTHROPIC_API_KEY (or put it in agent/api/.env and run `npm run agent`).");
    process.exit(1);
  }
  console.log(`PoB agent using ${MODEL} (effort ${EFFORT}). Waiting for messages in the Agent tab...`);
  for (;;) {
    let w;
    try {
      w = await rpc("chat_wait", { timeout: 50 });
    } catch (e) {
      await new Promise((r) => setTimeout(r, 5000));
      continue;
    }
    const got = w.result;
    if (!got || got.timedOut || !got.messages?.length) continue;

    // Transcript cleared in the panel (only the new messages are in it): start a fresh conversation
    const hist = await rpc("chat_history").catch(() => null);
    if (hist?.result && hist.result.messages.length <= got.messages.length) messages = [];

    const text = got.messages.join("\n\n");
    console.log(`> ${text}`);
    const start = messages.length;
    messages.push({ role: "user", content: `[Open build: ${got.build ?? "unnamed"}]\n${text}` });
    let out;
    try {
      out = await answer();
    } catch (e) {
      console.error(e);
      out = errorText(e);
      messages.length = start;
    }
    console.log(`< ${out}\n`);
    await reply(out).catch((e) => console.error("chat_reply failed:", e.message));
  }
}

main();
