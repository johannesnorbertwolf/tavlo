-- 0003 (#287): invite codes and APNs device tokens. Times are Unix milliseconds.

-- One row per invite code (`POST /v1/invites`). The match lives in its MatchRoom with an
-- open seat 1; the code is single use. `status` is written on every close; an `open` row
-- past `expires_at` reads as expired (the hourly cron also marks it and closes the match).
CREATE TABLE invites (
  code         TEXT PRIMARY KEY,
  match_id     TEXT NOT NULL,
  creator_id   TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  variant      TEXT NOT NULL,
  target_wins  INTEGER NOT NULL CHECK (target_wins IN (1, 2)),
  status       TEXT NOT NULL DEFAULT 'open'
               CHECK (status IN ('open', 'accepted', 'declined', 'cancelled', 'expired')),
  accepted_by  TEXT REFERENCES accounts (id) ON DELETE SET NULL,
  created_at   INTEGER NOT NULL,
  expires_at   INTEGER NOT NULL,
  closed_at    INTEGER
);
CREATE INDEX idx_invites_match ON invites (match_id);
CREATE INDEX idx_invites_open ON invites (status, expires_at);

-- APNs device tokens (`PUT /v1/push-tokens`). A token belongs to one device, so the newest
-- account that registers it owns it. Deleted with the account (cascade + deletion hook) and
-- when APNs answers that the token is no longer valid.
CREATE TABLE push_tokens (
  token        TEXT PRIMARY KEY,
  account_id   TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  environment  TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
  locale       TEXT,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
);
CREATE INDEX idx_push_tokens_account ON push_tokens (account_id, updated_at DESC);
