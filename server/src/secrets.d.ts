// Secrets are set with `wrangler secret put <NAME> --env <env>` and never live in
// wrangler.jsonc, so `wrangler types` cannot see them. All optional: the code skips
// the feature when one is missing. See REFERENCE.md "Runbook → Secrets".
interface TavtavSecrets {
  /** Account Analytics:Read API token for the hourly free-plan usage check. */
  CF_ANALYTICS_TOKEN?: string;
  /** Cloudflare account id the usage check queries. */
  CF_ACCOUNT_ID?: string;
  /** Where usage alerts go (ntfy.sh topic URL, Slack or Discord webhook). */
  ALERT_WEBHOOK_URL?: string;
}

interface Env extends TavtavSecrets {}
declare namespace Cloudflare {
  interface Env extends TavtavSecrets {}
}
