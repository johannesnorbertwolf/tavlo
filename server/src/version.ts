// Bump with package.json "version" (a test checks they match). The deployed commit
// comes from the GIT_COMMIT var (`wrangler deploy --var GIT_COMMIT:<sha>`, scripts/deploy.sh).
export const SERVER_VERSION = "0.1.0";
export const SERVICE_NAME = "tavtav-server";
