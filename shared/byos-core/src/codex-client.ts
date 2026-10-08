/**
 * Reviewed Codex compatibility identity. Account catalogs are version-sensitive: keep their
 * query and the TLS transport headers on one version, rather than freezing each consumer.
 * Verified against OpenAI's stable @openai/codex release on 2026-10-08:
 * https://github.com/openai/codex/releases/tag/rust-v0.161.0
 * This is protocol metadata, not a model allowlist or proof of account entitlement.
 */
export const CODEX_CLIENT_VERSION = '0.161.0';
export const CODEX_ACCOUNT_CATALOG_URL = `https://chatgpt.com/backend-api/codex/models?client_version=${CODEX_CLIENT_VERSION}`;
