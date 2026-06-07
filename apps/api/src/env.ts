/** Bindings and vars available to the Worker. Configured in wrangler.toml + secrets. */
export interface Env {
  DB: D1Database;

  // APNs configuration
  APNS_ENVIRONMENT: "sandbox" | "production";
  APNS_TEAM_ID: string;
  APNS_KEY_ID: string;
  APNS_BUNDLE_ID: string;
  APNS_PRIVATE_KEY: string; // secret — PKCS#8 .p8 contents

  // iOS remote config
  IOS_MIN_BUILD: string;
  IOS_LATEST_BUILD: string;
}
