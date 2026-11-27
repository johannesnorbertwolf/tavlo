-- 0002 (#285): sessions (rotating refresh tokens) + the Apple refresh token kept for
-- revocation on account deletion. Times are Unix milliseconds.

-- One row per signed-in device. Only SHA-256 hashes of refresh tokens are stored: the
-- current one and the one it replaced (presenting the replaced one again = reuse →
-- the session is revoked). Access tokens are stateless (HMAC, 1 h) and carry `id` as `sid`.
CREATE TABLE sessions (
  id             TEXT PRIMARY KEY,
  account_id     TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  refresh_hash   TEXT NOT NULL UNIQUE,
  previous_hash  TEXT,
  created_at     INTEGER NOT NULL,
  refreshed_at   INTEGER NOT NULL,
  expires_at     INTEGER NOT NULL
);
CREATE INDEX idx_sessions_account ON sessions (account_id);
CREATE INDEX idx_sessions_previous ON sessions (previous_hash);
CREATE INDEX idx_sessions_expires ON sessions (expires_at);

-- Sign in with Apple: Apple's refresh token from the authorization-code exchange, only
-- when the APPLE_* secrets are set; revoked at Apple when the account is deleted.
ALTER TABLE account_identities ADD COLUMN provider_refresh_token TEXT;
