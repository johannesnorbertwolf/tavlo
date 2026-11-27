// A tiny runtime schema kit: each schema both validates untrusted JSON and gives the
// static type (`Infer<typeof S>`), so the API contract (api.ts) has one source of truth.
// Objects ignore unknown keys (additive fields are not breaking, REFERENCE.md
// "Versioning"); absent optional keys stay absent.

export class SchemaError extends Error {
  constructor(
    readonly path: string,
    readonly problem: string,
  ) {
    super(`${path || "(root)"}: ${problem}`);
    this.name = "SchemaError";
  }
}

export interface Schema<T> {
  readonly parse: (value: unknown, path?: string) => T;
  readonly isOptional?: boolean;
}

export interface OptionalSchema<T> extends Schema<T | undefined> {
  readonly isOptional: true;
}

export type Infer<S> = S extends Schema<infer T> ? T : never;

const fail = (path: string, problem: string): never => {
  throw new SchemaError(path, problem);
};

export function str(opts: { min?: number; max?: number; pattern?: RegExp } = {}): Schema<string> {
  return {
    parse(v, path = "") {
      if (typeof v !== "string") return fail(path, "expected string");
      if (opts.min !== undefined && v.length < opts.min) fail(path, `shorter than ${opts.min}`);
      if (opts.max !== undefined && v.length > opts.max) fail(path, `longer than ${opts.max}`);
      if (opts.pattern && !opts.pattern.test(v)) fail(path, "has an invalid format");
      return v;
    },
  };
}

export function num(opts: { min?: number; max?: number; integer?: boolean } = {}): Schema<number> {
  return {
    parse(v, path = "") {
      if (typeof v !== "number" || !Number.isFinite(v)) return fail(path, "expected a finite number");
      if (opts.integer && !Number.isInteger(v)) fail(path, "expected an integer");
      if (opts.min !== undefined && v < opts.min) fail(path, `below ${opts.min}`);
      if (opts.max !== undefined && v > opts.max) fail(path, `above ${opts.max}`);
      return v;
    },
  };
}

export const int = (opts: { min?: number; max?: number } = {}) => num({ ...opts, integer: true });

export function bool(): Schema<boolean> {
  return {
    parse(v, path = "") {
      return typeof v === "boolean" ? v : fail(path, "expected boolean");
    },
  };
}

export function literal<const L extends readonly (string | number)[]>(...values: L): Schema<L[number]> {
  return {
    parse(v, path = "") {
      return (values as readonly unknown[]).includes(v)
        ? (v as L[number])
        : fail(path, `expected one of ${values.map((x) => JSON.stringify(x)).join(", ")}`);
    },
  };
}

export function nullable<T>(inner: Schema<T>): Schema<T | null> {
  return {
    parse(v, path = "") {
      return v === null ? null : inner.parse(v, path);
    },
  };
}

/** A key that may be absent. (Use `nullable` for a key that is present but may be null.) */
export function optional<T>(inner: Schema<T>): OptionalSchema<T> {
  return {
    isOptional: true,
    parse(v, path = "") {
      return v === undefined ? undefined : inner.parse(v, path);
    },
  };
}

export function array<T>(item: Schema<T>, opts: { min?: number; max?: number } = {}): Schema<T[]> {
  return {
    parse(v, path = "") {
      if (!Array.isArray(v)) return fail(path, "expected array");
      if (opts.min !== undefined && v.length < opts.min) fail(path, `fewer than ${opts.min} items`);
      if (opts.max !== undefined && v.length > opts.max) fail(path, `more than ${opts.max} items`);
      return v.map((x, i) => item.parse(x, `${path}[${i}]`));
    },
  };
}

type Shape = Record<string, Schema<unknown>>;
type OptionalKeys<S extends Shape> = {
  [K in keyof S]: S[K] extends OptionalSchema<unknown> ? K : never;
}[keyof S];
type RequiredKeys<S extends Shape> = Exclude<keyof S, OptionalKeys<S>>;
type Simplify<T> = { [K in keyof T]: T[K] } & {};
export type ObjectOf<S extends Shape> = Simplify<
  { [K in RequiredKeys<S>]: Infer<S[K]> } & { [K in OptionalKeys<S>]?: Exclude<Infer<S[K]>, undefined> }
>;

export function object<S extends Shape>(shape: S): Schema<ObjectOf<S>> {
  return {
    parse(v, path = "") {
      if (typeof v !== "object" || v === null || Array.isArray(v)) return fail(path, "expected object");
      const src = v as Record<string, unknown>;
      const out: Record<string, unknown> = {};
      for (const [key, schema] of Object.entries(shape)) {
        const sub = path ? `${path}.${key}` : key;
        if (!(key in src) || src[key] === undefined) {
          if (!schema.isOptional) fail(sub, "is required");
          continue;
        }
        out[key] = schema.parse(src[key], sub);
      }
      return out as ObjectOf<S>;
    },
  };
}

/** A union of object schemas told apart by a string tag (e.g. WebSocket `type`). */
export function tagged<K extends string, M extends Record<string, Schema<object>>>(
  key: K,
  members: M,
): Schema<{ [T in keyof M]: Infer<M[T]> & { [P in K]: T } }[keyof M]> {
  return {
    parse(v, path = "") {
      if (typeof v !== "object" || v === null) return fail(path, "expected object");
      const tag = (v as Record<string, unknown>)[key];
      const sub = path ? `${path}.${key}` : key;
      if (typeof tag !== "string" || !(tag in members)) return fail(sub, "unknown tag");
      return { ...members[tag]!.parse(v, path), [key]: tag } as never;
    },
  };
}
