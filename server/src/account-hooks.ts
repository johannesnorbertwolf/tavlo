// What else must happen when an account is deleted (DELETE /v1/account), before its
// D1 rows go. #285 deletes the personal data; #286 registers a hook here that, for each
// match in `matchIDs`, asks the MatchRoom to end a running match as a quit and to
// anonymise the player (displayName → null) in finished ones. #287 adds push tokens.
// A hook that throws aborts the deletion (500, nothing deleted), so the app can retry.

import type { Logger } from "./log";

export interface AccountDeletion {
  accountID: string;
  /** The account's matches from `match_index` (the rows cascade away afterwards). */
  matchIDs: string[];
}

export type AccountDeletionHook = (env: Env, deletion: AccountDeletion, log: Logger) => Promise<void>;

/** Registered hooks, run in order. Empty until #286 / #287. */
export const ACCOUNT_DELETION_HOOKS: AccountDeletionHook[] = [];

export async function runAccountDeletionHooks(env: Env, accountID: string, log: Logger): Promise<AccountDeletion> {
  const { results } = await env.DB.prepare("SELECT match_id FROM match_index WHERE account_id = ?")
    .bind(accountID)
    .all<{ match_id: string }>();
  const deletion = { accountID, matchIDs: results.map((r) => r.match_id) };
  for (const hook of ACCOUNT_DELETION_HOOKS) await hook(env, deletion, log);
  return deletion;
}
