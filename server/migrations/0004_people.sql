-- 0004 (#301): people you've played, presence privacy, one-tap challenges. Times are Unix ms.

-- A match counts for the people list once both seats played in it (both accepted / joined):
-- written by the MatchRoom with every index row. A declined, cancelled or expired challenge
-- never makes two players "people" (that is also who may see whose online status).
ALTER TABLE match_index ADD COLUMN played INTEGER NOT NULL DEFAULT 0;
-- Backfill: both rows of the match exist, neither side is still invited / waiting, and an
-- ended match had a result (outcome none = declined / closed before anyone played).
UPDATE match_index SET played = 1
WHERE opponent_id IS NOT NULL AND match_id IN (
  SELECT match_id FROM match_index GROUP BY match_id
  HAVING COUNT(*) = 2
     AND SUM(state IN ('invited', 'waitingForOpponent')) = 0
     AND SUM(state = 'ended' AND outcome = 'none') = 0
);
CREATE INDEX idx_match_index_people ON match_index (account_id, played, opponent_id, updated_at);

-- "Show when I'm online" off: nobody sees this account's presence.
ALTER TABLE accounts ADD COLUMN hide_presence INTEGER NOT NULL DEFAULT 0;
-- "Who can challenge me": everyone (default) or only my people.
ALTER TABLE accounts ADD COLUMN challenge_policy TEXT NOT NULL DEFAULT 'everyone'
  CHECK (challenge_policy IN ('everyone', 'people'));

-- Handles (find each other, like Lichess): 3–20 of [A-Za-z0-9_], shown as typed, unique
-- case-insensitively via `handle_key` (= lower(handle)). A generated handle may be changed
-- once (`handle_chosen` 0 → 1). Existing accounts get a generated one here.
ALTER TABLE accounts ADD COLUMN handle TEXT;
ALTER TABLE accounts ADD COLUMN handle_key TEXT;
ALTER TABLE accounts ADD COLUMN handle_chosen INTEGER NOT NULL DEFAULT 0;
UPDATE accounts SET handle = 'player_' || lower(hex(randomblob(4))) WHERE handle IS NULL;
UPDATE accounts SET handle_key = lower(handle) WHERE handle_key IS NULL;
CREATE UNIQUE INDEX idx_accounts_handle ON accounts (handle_key);

-- Blocks: the blocked account can't challenge the blocker, find it in search or see its
-- status, and neither shows in the other's people list.
CREATE TABLE blocks (
  blocker_id  TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  blocked_id  TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (blocker_id, blocked_id)
);
CREATE INDEX idx_blocks_blocked ON blocks (blocked_id);

-- The caller's choices about one person of its list (the list itself is derived from
-- match_index). `pinned` = ⭐, also how someone found by handle is added to the list;
-- `removed_at`: hidden until a game newer than that is played.
CREATE TABLE contact_prefs (
  account_id  TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  contact_id  TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  pinned      INTEGER NOT NULL DEFAULT 0,
  removed_at  INTEGER,
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (account_id, contact_id)
);
CREATE INDEX idx_contact_prefs_contact ON contact_prefs (contact_id);

-- A direct challenge (`POST /v1/matches` with `opponentID`): the match waits in its
-- MatchRoom with seat 1 `invited`; this row is its lifecycle. Every change is one
-- conditional UPDATE `WHERE status = 'pending'`, so accept / decline / cancel / expire race
-- safely (exactly one wins).
CREATE TABLE challenges (
  match_id       TEXT PRIMARY KEY,
  challenger_id  TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  challenged_id  TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  variant        TEXT NOT NULL,
  target_wins    INTEGER NOT NULL CHECK (target_wins IN (1, 2)),
  status         TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'accepted', 'declined', 'expired', 'cancelled')),
  created_at     INTEGER NOT NULL,
  expires_at     INTEGER NOT NULL,
  answered_at    INTEGER
);
CREATE INDEX idx_challenges_pending ON challenges (status, expires_at);
CREATE INDEX idx_challenges_challenger ON challenges (challenger_id, status);
CREATE INDEX idx_challenges_challenged ON challenges (challenged_id, status);
-- At most one pending challenge per direction between two players (a second tap answers
-- the first; a stale pending row past its expiry is marked expired before a new insert).
CREATE UNIQUE INDEX idx_challenges_one_pending ON challenges (challenger_id, challenged_id) WHERE status = 'pending';
