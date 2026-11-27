// Structured logging: one JSON object per line, picked up by Workers Logs
// (observability.enabled) and `wrangler tail`. Never log tokens, payloads or IPs.

export type LogLevel = "debug" | "info" | "warn" | "error";
export type LogFields = Record<string, unknown>;

const SINKS: Record<LogLevel, (line: string) => void> = {
  debug: (l) => console.debug(l),
  info: (l) => console.log(l),
  warn: (l) => console.warn(l),
  error: (l) => console.error(l),
};

function serialize(value: unknown): unknown {
  if (value instanceof Error) return { name: value.name, message: value.message, stack: value.stack };
  return value;
}

export class Logger {
  constructor(private readonly base: LogFields = {}) {}

  /** A logger that adds `fields` to every line. */
  child(fields: LogFields): Logger {
    return new Logger({ ...this.base, ...fields });
  }

  log(level: LogLevel, event: string, fields: LogFields = {}): void {
    const line: LogFields = { level, event, ts: new Date().toISOString(), ...this.base };
    for (const [k, v] of Object.entries(fields)) line[k] = serialize(v);
    SINKS[level](JSON.stringify(line));
  }

  debug(event: string, fields?: LogFields): void {
    this.log("debug", event, fields);
  }
  info(event: string, fields?: LogFields): void {
    this.log("info", event, fields);
  }
  warn(event: string, fields?: LogFields): void {
    this.log("warn", event, fields);
  }
  error(event: string, fields?: LogFields): void {
    this.log("error", event, fields);
  }
}
