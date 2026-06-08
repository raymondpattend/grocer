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

  // iOS remote config
  IOS_MIN_BUILD: string;
  IOS_LATEST_BUILD: string;

  // OpenAI — used for product image generation + embeddings
  OPENAI_API_KEY: string;
}
