import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { spawn } from "node:child_process";
import {
  createServer as createHttpServer,
  request as httpRequest,
} from "node:http";
import type { IncomingMessage, Server, ServerResponse } from "node:http";
import { createServer as createNetServer } from "node:net";
import type { AddressInfo } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const tapesDir = path.join(__dirname, "../tapes");
const mode = process.env.FIXTURE_MODE || "replay";
const scenario = process.env.FIXTURE_SCENARIO || "default";
const ollamaHost = process.env.OLLAMA_HOST || "http://127.0.0.1:11434";

const binPath = path.join(__dirname, "../node_modules/.bin/proxay");
const logFile = "/tmp/proxay.log";

// Keep a single proxay per agent process across module re-imports, bound to
// an OS-assigned free port.
const PROXAY_STATE_KEY = "__pimacsFixtureProxayState__";
const PROXAY_HANDLERS_KEY = "__pimacsFixtureProxayHandlers__";

interface ProxayState {
  proxay: ReturnType<typeof spawn>;
  port: number;
}

interface GateDefinition {
  name: string;
  prompt: string;
}

interface Gate {
  name: string;
  prompt: string;
  released: boolean;
  resolvers: Array<() => void>;
}

interface GatewayState {
  gates: Map<string, Gate>;
  port: number;
  server: Server;
}

const GATEWAY_STATE_KEY = "__pimacsFixtureGatewayState__";

function logGateway(message: string): void {
  appendFileSync(logFile, `[gateway] ${message}\n`);
}

function getGlobalStore(): Record<string, unknown> {
  return globalThis as unknown as Record<string, unknown>;
}

function getProxayState(): ProxayState | undefined {
  return getGlobalStore()[PROXAY_STATE_KEY] as ProxayState | undefined;
}

function getGatewayState(): GatewayState | undefined {
  return getGlobalStore()[GATEWAY_STATE_KEY] as GatewayState | undefined;
}

function loadGateDefinitions(): GateDefinition[] {
  const gateFile = path.join(tapesDir, `${scenario}.gates.json`);
  if (!existsSync(gateFile)) {
    return [];
  }
  const parsed: unknown = JSON.parse(readFileSync(gateFile, "utf8"));
  if (
    typeof parsed !== "object" ||
    parsed === null ||
    !Array.isArray((parsed as { gates?: unknown }).gates)
  ) {
    throw new Error(`Invalid fixture gates file: ${gateFile}`);
  }
  return (parsed as { gates: unknown[] }).gates.map((gate) => {
    const definition = gate as GateDefinition;
    if (
      typeof gate !== "object" ||
      gate === null ||
      typeof definition.name !== "string" ||
      typeof definition.prompt !== "string"
    ) {
      throw new Error(`Invalid fixture gate in: ${gateFile}`);
    }
    return gate as GateDefinition;
  });
}

function getLastUserPrompt(body: Buffer): string | undefined {
  let request: { messages?: Array<{ content?: unknown; role?: unknown }> };
  try {
    request = JSON.parse(body.toString("utf8"));
  } catch {
    return undefined;
  }
  const message = request.messages
    ?.slice()
    .reverse()
    .find((entry) => entry.role === "user");
  if (typeof message?.content === "string") {
    return message.content;
  }
  if (Array.isArray(message?.content)) {
    return message.content
      .filter(
        (part): part is { text: string; type: string } =>
          typeof part === "object" &&
          part !== null &&
          (part as { type?: unknown }).type === "text" &&
          typeof (part as { text?: unknown }).text === "string",
      )
      .map((part) => part.text)
      .join("\n");
  }
  return undefined;
}

function waitForGate(gate: Gate, response: ServerResponse): Promise<boolean> {
  if (gate.released) {
    return Promise.resolve(true);
  }
  if (response.destroyed) {
    return Promise.resolve(false);
  }
  return new Promise((resolve) => {
    const release = () => {
      response.removeListener("close", cancel);
      resolve(true);
    };
    const cancel = () => {
      const index = gate.resolvers.indexOf(release);
      if (index >= 0) {
        gate.resolvers.splice(index, 1);
      }
      resolve(false);
    };
    gate.resolvers.push(release);
    response.once("close", cancel);
  });
}

function releaseGate(gate: Gate): void {
  logGateway(`releasing gate=${gate.name} waiters=${gate.resolvers.length}`);
  gate.released = true;
  for (const resolve of gate.resolvers.splice(0)) {
    resolve();
  }
}

function forwardRequest(
  request: IncomingMessage,
  response: ServerResponse,
  proxayPort: number,
  body: Buffer,
): void {
  const upstream = httpRequest(
    {
      hostname: "127.0.0.1",
      port: proxayPort,
      path: request.url,
      method: request.method,
      headers: request.headers,
    },
    (upstreamResponse) => {
      response.writeHead(
        upstreamResponse.statusCode ?? 502,
        upstreamResponse.headers,
      );
      upstreamResponse.pipe(response);
    },
  );
  upstream.on("error", (error) => {
    if (!response.headersSent) {
      response.writeHead(502);
    }
    response.end(error.message);
  });
  upstream.end(body);
}

async function handleGatewayRequest(
  request: IncomingMessage,
  response: ServerResponse,
  proxayPort: number,
  gates: Map<string, Gate>,
): Promise<void> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  const body = Buffer.concat(chunks);
  const prompt = getLastUserPrompt(body);
  const gate = prompt
    ? Array.from(gates.values()).find(
        (entry) => !entry.released && entry.prompt === prompt,
      )
    : undefined;
  if (gate) {
    logGateway(`holding gate=${gate.name} prompt=${JSON.stringify(prompt)}`);
    if (!(await waitForGate(gate, response))) {
      logGateway(`cancelled gate=${gate.name}; dropping request`);
      return;
    }
    logGateway(`released gate=${gate.name}; forwarding request`);
  }
  forwardRequest(request, response, proxayPort, body);
}

async function initializeGateway(
  proxay: ProxayState,
): Promise<GatewayState | undefined> {
  const definitions = loadGateDefinitions();
  if (definitions.length === 0) {
    return undefined;
  }
  const existing = getGatewayState();
  if (existing?.server.listening) {
    return existing;
  }
  const gates = new Map(
    definitions.map((definition) => [
      definition.name,
      {
        name: definition.name,
        prompt: definition.prompt,
        released: false,
        resolvers: [],
      },
    ]),
  );
  const server = createHttpServer((request, response) => {
    void handleGatewayRequest(request, response, proxay.port, gates);
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const state = {
    gates,
    port: (server.address() as AddressInfo).port,
    server,
  };
  logGateway(
    `started port=${state.port} gates=${definitions.map((gate) => gate.name).join(",")}`,
  );
  getGlobalStore()[GATEWAY_STATE_KEY] = state;
  return state;
}
function getFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createNetServer();
    server.once("error", reject);
    server.listen(0, () => {
      const port = (server.address() as AddressInfo).port;
      server.close(() => resolve(port));
    });
  });
}

async function initialize(): Promise<{
  gates: Map<string, Gate>;
  port: number;
}> {
  let proxay = getProxayState();
  if (
    !proxay ||
    proxay.proxay.exitCode !== null ||
    proxay.proxay.signalCode !== null
  ) {
    const port = await getFreePort();
    const process = spawn(binPath, [
      "--mode",
      mode,
      "--tapes-dir",
      tapesDir,
      "--default-tape",
      scenario,
      "--host",
      ollamaHost,
      "--port",
      String(port),
    ]);

    process.stdout.on("data", (data) => {
      appendFileSync(logFile, `[stdout] ${data.toString()}`);
    });

    process.stderr.on("data", (data) => {
      appendFileSync(logFile, `[stderr] ${data.toString()}`);
    });

    process.on("exit", (code) => {
      appendFileSync(logFile, `[exit] code=${code}\n`);
    });

    proxay = { proxay: process, port };
    getGlobalStore()[PROXAY_STATE_KEY] = proxay;
  }
  const gateway = await initializeGateway(proxay);
  return {
    gates: gateway?.gates ?? new Map(),
    port: gateway?.port ?? proxay.port,
  };
}

export default async function (pi: ExtensionAPI) {
  const { gates, port } = await initialize();

  if (!getGlobalStore()[PROXAY_HANDLERS_KEY]) {
    getGlobalStore()[PROXAY_HANDLERS_KEY] = true;

    [
      "exit",
      "SIGINT",
      "SIGUSR1",
      "SIGUSR2",
      "uncaughtException",
      "SIGTERM",
    ].forEach((eventType) => {
      process.on(eventType, () => {
        appendFileSync(logFile, `[pi](${eventType}) stopping proxay\n`);
        getProxayState()?.proxay.kill();
        getGatewayState()?.server.close();
      });
    });
  }

  if (gates.size > 0) {
    pi.registerCommand("fixture-release", {
      description: "Release a named fixture gateway.",
      handler: async (args) => {
        const gate = gates.get(String(args).trim());
        if (!gate) {
          throw new Error(`Unknown fixture gate: ${args}`);
        }
        releaseGate(gate);
      },
    });
  }
  pi.registerTool({
    name: "cowsay",
    label: "cowsay",
    description: "Say a message using a cow.",
    parameters: Type.Object({
      message: Type.String({ description: "The message for the cow to say." }),
    }),
    execute: async (_toolCallId, params) => ({
      content: [
        {
          type: "text",
          text: ` ______
< ${params.message} >
 ------
        \\   ^__^
         \\  (oo)\\_______
            (__)\\       )\\/\\
                ||----w |
                ||     ||`,
        },
      ],
      details: {},
    }),
  });

  pi.registerCommand("rpc-input", {
    description: "Prompt for text input (ctx.ui.input)",
    handler: async (_args, ctx) => {
      const value = await ctx.ui.input("Enter a value", "type something...");
      ctx.ui.notify(`Input result: ${value ?? "cancelled"}`, "info");
    },
  });

  pi.registerCommand("rpc-confirm", {
    description: "Prompt for confirmation (ctx.ui.confirm)",
    handler: async (_args, ctx) => {
      const confirmed = await ctx.ui.confirm(
        "Continue?",
        "Do you want to proceed?",
      );
      ctx.ui.notify(`Confirmed: ${confirmed}`, "info");
    },
  });

  pi.registerCommand("rpc-select", {
    description: "Prompt for selection (ctx.ui.select)",
    handler: async (_args, ctx) => {
      const value = await ctx.ui.select("Pick an option", [
        "Option A",
        "Option B",
        "Option C",
      ]);
      ctx.ui.notify(`Selected: ${value ?? "cancelled"}`, "info");
    },
  });

  pi.registerCommand("rpc-notify", {
    description: "Send notifications (ctx.ui.notify)",
    handler: async (_args, ctx) => {
      ctx.ui.notify("Info notification", "info");
      ctx.ui.notify("Warning notification", "warning");
      ctx.ui.notify("Error notification", "error");
    },
  });

  pi.registerCommand("rpc-editor", {
    description: "Open editor (ctx.ui.editor)",
    handler: async (_args, ctx) => {
      const value = await ctx.ui.editor("Edit some text", "prefilled text");
      ctx.ui.notify(`Editor result: ${value ?? "cancelled"}`, "info");
    },
  });

  pi.registerCommand("rpc-set-editor-text", {
    description: "Set editor text (ctx.ui.setEditorText)",
    handler: async (_args, ctx) => {
      ctx.ui.setEditorText("hello from extension");
      ctx.ui.notify("Editor text set", "info");
    },
  });

  pi.registerCommand("rpc-set-widget", {
    description: "Set widgets above and below editor (ctx.ui.setWidget)",
    handler: async (_args, ctx) => {
      ctx.ui.setWidget("rpc-widget-above", ["Widget line 1", "Widget line 2"]);
      ctx.ui.setWidget("rpc-widget-below", ["Widget line 3", "Widget line 4"], {
        placement: "belowEditor",
      });
      ctx.ui.notify("Widget set", "info");
    },
  });

  pi.registerCommand("rpc-set-status", {
    description: "Set status (ctx.ui.setStatus)",
    handler: async (_args, ctx) => {
      ctx.ui.setStatus("rpc-status-a", "Status A value");
      ctx.ui.setStatus("rpc-status-b", "Status B value");
      ctx.ui.notify("Status set", "info");
    },
  });

  pi.registerCommand("rpc-set-title", {
    description: "Set title (ctx.ui.setTitle)",
    handler: async (_args, ctx) => {
      ctx.ui.setTitle("Custom Title");
      ctx.ui.notify("Title set", "info");
    },
  });

  pi.registerProvider("fixture", {
    api: "openai-completions",
    baseUrl: `http://127.0.0.1:${port}/v1`,
    apiKey: "ollama",
    models: [
      {
        id: "gemma4:12b",
        name: "gemma4:12b",
        reasoning: true,
        input: ["text", "image"],
        cost: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
        },
        contextWindow: 200000,
        maxTokens: 100000,
      },
    ],
  });
}
