import { SessionManager } from "@earendil-works/pi-coding-agent";

const [sessionFile, ...extraArgs] = process.argv.slice(2);

if (!sessionFile || extraArgs.length > 0) {
  console.error("Usage: get_entries <session-file>");
  process.exit(1);
}

const sessionManager = SessionManager.open(sessionFile);
const response = {
  id: "get_entries",
  type: "response",
  command: "get_entries",
  success: true,
  data: {
    entries: sessionManager.getEntries(),
    leafId: sessionManager.getLeafId(),
  },
};

process.stdout.write(`${JSON.stringify(response)}\n`);
