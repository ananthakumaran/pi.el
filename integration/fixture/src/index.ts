import { appendFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
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

function getGlobalStore(): Record<string, unknown> {
  return globalThis as unknown as Record<string, unknown>;
}

function getProxayState(): ProxayState | undefined {
  return getGlobalStore()[PROXAY_STATE_KEY] as ProxayState | undefined;
}

function getFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, () => {
      const port = (server.address() as AddressInfo).port;
      server.close(() => resolve(port));
    });
  });
}

async function initialize(): Promise<ProxayState> {
  const existing = getProxayState();
  if (
    existing &&
    existing.proxay.exitCode === null &&
    existing.proxay.signalCode === null
  ) {
    return existing;
  }

  const port = await getFreePort();
  const proxay = spawn(binPath, [
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

  proxay.stdout.on("data", (data) => {
    appendFileSync(logFile, `[stdout] ${data.toString()}`);
  });

  proxay.stderr.on("data", (data) => {
    appendFileSync(logFile, `[stderr] ${data.toString()}`);
  });

  proxay.on("exit", (code) => {
    appendFileSync(logFile, `[exit] code=${code}\n`);
  });

  const state = { proxay, port };
  getGlobalStore()[PROXAY_STATE_KEY] = state;
  return state;
}

export default async function (pi: ExtensionAPI) {
  const { port } = await initialize();

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
      });
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
        input: ["text"],
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
