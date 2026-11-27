-- 0001 (#284): accounts, sign-in identities, the per-player match index, ops dedupe.
-- Times are Unix milliseconds. Applied with `wrangler d1 migrations apply DB --env <env> --remote`
-- (scripts/deploy.sh does it before every deploy). Never edit a shipped migration: add 0002_….

-- One row per player. `id` is the playerID of the API and of the match payload's colorByPlayerID.
CREATE TABLE accounts (
  id            TEXT PRIMARY KEY,
  display_name  TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  last_seen_at  INTEGER NOT NULL
);

-- Sign in with Apple / Google subjects (the token's `sub`) linked to an account (#285).
CREATE TABLE account_identities (
  provider    TEXT NOT NULL CHECK (provider IN ('apple', 'google')),
  subject     TEXT NOT NULL,
  account_id  TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (provider, subject)
);
CREATE INDEX idx_account_identities_account ON account_identities (account_id);

-- Each player's matches for the lobby (#286 writes it from the MatchRoom, #287 reads it).
-- One row per (match, player); the MatchRoom Durable Object is the source of truth.
CREATE TABLE match_index (
  match_id     TEXT NOT NULL,
  account_id   TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  opponent_id  TEXT,
  variant      TEXT NOT NULL,
  target_wins  INTEGER NOT NULL CHECK (target_wins IN (1, 2)),
  state        TEXT NOT NULL
               CHECK (state IN ('invited', 'yourTurn', 'theirTurn', 'waitingForOpponent', 'ended')),
  outcome      TEXT NOT NULL DEFAULT 'none',
  hidden       INTEGER NOT NULL DEFAULT 0,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  PRIMARY KEY (match_id, account_id)
);
CREATE INDEX idx_match_index_lobby ON match_index (account_id, hidden, updated_at DESC);

-- Once-per-day dedupe for ops alerts (usage.ts): key = (UTC day, alert kind).
CREATE TABLE ops_alerts (
  day         TEXT NOT NULL,
  kind        TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (day, kind)
);
