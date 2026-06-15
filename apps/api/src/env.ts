/** Bindings and vars available to the Worker. Configured in wrangler.toml + secrets. */
export interface Env {
  DB: D1Database;
  IMAGES: R2Bucket;
  IMAGE_INDEX: VectorizeIndex;

  // APNs configuration
  APNS_ENVIRONMENT: "sandbox" | "production";
  APNS_TEAM_ID: string;
  APNS_KEY_ID: string;
  APNS_BUNDLE_ID: string;
  APNS_PRIVATE_KEY: string; // secret — PKCS#8 .p8 contents
  APNS_HTTP2_BRIDGE_URL?: string; // local dev only — APNs requires HTTP/2
  LIVE_ACTIVITY_API_SECRET: string; // secret — HMAC key for app-signed Live Activity requests

  // iOS remote config
  IOS_MIN_BUILD: string;
  IOS_LATEST_BUILD: string;
  IOS_UPDATE_URL?: string;

  // OpenAI — used for product image generation, embeddings, and list parsing
  OPENAI_API_KEY: string;
  OPENAI_PARSE_MODEL?: string;

  // PostHog analytics
  POSTHOG_API_KEY: string;
  POSTHOG_HOST: string;
}
