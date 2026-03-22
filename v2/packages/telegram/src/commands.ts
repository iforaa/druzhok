const KNOWN_COMMANDS = new Set(["start", "stop", "reset", "prompt", "model"]);

export type ParsedCommand = { command: string; args: string };

export function parseCommand(text: string): ParsedCommand | null {
  if (!text || !text.startsWith("/")) return null;
  const parts = text.split(/\s+/);
  const command = parts[0].slice(1).replace(/@\S+$/, "").toLowerCase();
  if (!KNOWN_COMMANDS.has(command)) return null;
  return { command, args: parts.slice(1).join(" ").trim() };
}
