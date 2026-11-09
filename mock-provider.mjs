import http from "node:http";
import fs from "node:fs";

const PORT = 19537;
const LOG = "/tmp/proof/requests.log";
const EXEC_COMMAND =
  'pwd && printf "MARKER_COMMA_195304\\n" > MARKER_COMMA_195304.txt && echo HOME=$HOME && ls -la MARKER_COMMA_195304.txt';

function log(line) {
  try {
    fs.appendFileSync(LOG, `${new Date().toISOString()} ${line}\n`);
  } catch {}
}

function describeRequest(body) {
  const messages = Array.isArray(body.messages) ? body.messages : [];
  const tools = Array.isArray(body.tools) ? body.tools.map((t) => t?.function?.name ?? t?.name) : [];
  const last = messages.at(-1) ?? {};
  return `messages=${messages.length} hasToolResult=${messages.some((m) => m?.role === "tool")} tools=${JSON.stringify(tools)} lastRole=${last.role}`;
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => resolve(data));
  });
}

const server = http.createServer(async (req, res) => {
  const url = req.url ?? "";
  if (req.method === "GET" && url.includes("/models")) {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        object: "list",
        data: [{ id: "proof-model", object: "model", created: 0, owned_by: "prooflocal" }],
      }),
    );
    return;
  }
  if (req.method === "POST" && url.includes("/chat/completions")) {
    const raw = await readBody(req);
    let body = {};
    try {
      body = JSON.parse(raw);
    } catch {}
    const messages = Array.isArray(body.messages) ? body.messages : [];
    const hasToolResult = messages.some((m) => m && m.role === "tool");
    log(`POST chat/completions ${describeRequest(body)}`);
    let message;
    let finish_reason;
    if (hasToolResult) {
      message = {
        role: "assistant",
        content: "COMMA_WORKSPACE_PROOF_OK: marker written inside the container workspace.",
      };
      finish_reason = "stop";
    } else {
      message = {
        role: "assistant",
        content: null,
        tool_calls: [
          {
            id: "call_comma_195304",
            type: "function",
            function: { name: "exec", arguments: JSON.stringify({ command: EXEC_COMMAND }) },
          },
        ],
      };
      finish_reason = "tool_calls";
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        id: "chatcmpl-comma195304",
        object: "chat.completion",
        created: Math.floor(Date.now() / 1000),
        model: body.model ?? "proof-model",
        choices: [{ index: 0, message, finish_reason }],
        usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 },
      }),
    );
    return;
  }
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify({ ok: true }));
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`mock provider ready on ${PORT}`);
  log("mock provider ready");
});