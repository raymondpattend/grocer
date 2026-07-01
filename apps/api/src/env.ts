/** Bindings and vars available to the Worker. Configured in wrangler.toml + secrets. */
export interface Env {
  DB: D1Database;
  IMAGES: R2Bucket;
  IMAGE_INDEX: VectorizeIndex;
  // AI-route rate limiters (Cloudflare native ratelimit bindings). Keyed on the
  // trustworthy CF-Connecting-IP as the hard ceiling; the per-id/image buckets
  // layer on top. See lib/aiRateLimit.ts.
  AI_RL_PER_10S: RateLimit; // per-IP burst
  AI_RL_PER_MIN: RateLimit; // per-IP sustained (hard ceiling)
  AI_RL_ID_PER_MIN: RateLimit; // per-distinct-id fair-share cap
  AI_RL_IMAGE_PER_MIN: RateLimit; // tighter per-IP cap for paid image generation

  // APNs configuration
  APNS_ENVIRONMENT: "sandbox" | "production";
  APNS_TEAM_ID: string;
  APNS_KEY_ID: string;
  APNS_BUNDLE_ID: string;
  APNS_ACTIVITY_ATTRIBUTES_TYPE?: string;
  APNS_PRIVATE_KEY: string; // secret — PKCS#8 .p8 contents
  APNS_HTTP2_BRIDGE_URL?: string; // local dev only — APNs requires HTTP/2
  LIVE_ACTIVITY_API_SECRET: string; // secret — HMAC key for app-signed Live Activity requests

  // iOS remote config
  IOS_MIN_BUILD: string;
  IOS_LATEST_BUILD: string;
  IOS_UPDATE_URL?: string;
  IOS_EXTERNAL_PURCHASE_STOREFRONTS?: string;

  // Billing / web checkout
  STRIPE_SECRET_KEY: string;
  STRIPE_PUBLISHABLE_KEY: string; // pk_… — used by the custom Stripe Elements checkout page
  STRIPE_PRICE_ANNUAL: string;
  STRIPE_PRICE_QUARTERLY: string;
  STRIPE_PRICE_MONTHLY: string;

  // OpenAI — used for product image generation, embeddings, and list parsing
  OPENAI_API_KEY: string;
  OPENAI_PARSE_MODEL?: string;

  // Grafana OpenAI monitoring. Access token is a secret.
  GRAFANA_OPENAI_METRICS_URL?: string;
  GRAFANA_OPENAI_LOGS_URL?: string;
  GRAFANA_OPENAI_METRICS_USERNAME?: string;
  GRAFANA_OPENAI_LOGS_USERNAME?: string;
  GRAFANA_CLOUD_ACCESS_TOKEN?: string;

  // PostHog analytics
  POSTHOG_API_KEY: string;
  POSTHOG_HOST: string;
}
