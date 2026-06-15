import { Hono } from "hono";
import Stripe from "stripe";
import type { Env } from "../env.js";

const REVENUECAT_USER_METADATA_KEY = "user_id";
const LEGACY_APP_USER_METADATA_KEY = "app_user_id";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type BillingBindings = { Bindings: Env };
type StripeClient = Stripe;

type BillingDeps = {
  getStripe: (env: Env) => StripeClient;
};

type BillingPlan = {
  key: "annual" | "quarterly" | "monthly";
  title: string;
  packageId: string;
  priceEnv: "STRIPE_PRICE_ANNUAL" | "STRIPE_PRICE_QUARTERLY" | "STRIPE_PRICE_MONTHLY";
  aliases: string[];
};

const PLANS: BillingPlan[] = [
  {
    key: "annual",
    title: "Annual",
    packageId: "$rc_annual",
    priceEnv: "STRIPE_PRICE_ANNUAL",
    aliases: [
      "$rc_annual",
      "annual",
      "yearly",
      "grocer_pro_subscription_annual_1",
    ],
  },
  {
    key: "quarterly",
    title: "Quarterly",
    packageId: "$rc_three_month",
    priceEnv: "STRIPE_PRICE_QUARTERLY",
    aliases: [
      "$rc_three_month",
      "$rc_quarterly",
      "quarterly",
      "three_month",
      "grocer_pro_subscription_quarterly_1",
    ],
  },
  {
    key: "monthly",
    title: "Monthly",
    packageId: "$rc_monthly",
    priceEnv: "STRIPE_PRICE_MONTHLY",
    aliases: [
      "$rc_monthly",
      "monthly",
      "grocer_pro_subscription_monthly_1",
    ],
  },
];

export function createBillingRoute(overrides: Partial<BillingDeps> = {}) {
  const deps: BillingDeps = {
    getStripe: defaultStripe,
    ...overrides,
  };
  const route = new Hono<BillingBindings>();

  route.get("/checkout", async (c) => {
    const input = parseCheckoutParams(c.req.query("packageId"), c.req.query("uid"));
    if (!input.ok) {
      return c.html(errorPage("Checkout unavailable", input.error), 400);
    }

    const plan = planForPackageId(input.packageId);
    if (!plan) {
      return c.html(errorPage("Plan unavailable", "This plan is not available for web checkout."), 400);
    }

    const priceId = c.env[plan.priceEnv]?.trim();
    if (!priceId) {
      return c.html(errorPage("Checkout unavailable", "This plan is not configured yet."), 500);
    }

    const stripe = deps.getStripe(c.env);
    const customer = await findOrCreateCustomer(stripe, input.uid);
    const url = new URL(c.req.url);
    const alreadyActive = await findActiveSubscription(stripe, customer.id);
    if (alreadyActive) {
      const successUrl = new URL("/checkout/success", url.origin);
      successUrl.searchParams.set("already_active", "1");
      successUrl.searchParams.set("uid", input.uid);
      return c.redirect(successUrl.toString(), 303);
    }

    const metadata = checkoutMetadata(input.uid, plan);
    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: customer.id,
      client_reference_id: input.uid,
      line_items: [{ price: priceId, quantity: 1 }],
      payment_method_types: ["card"],
      metadata,
      subscription_data: { metadata },
      success_url: `${url.origin}/checkout/success?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${url.origin}/checkout/cancelled`,
    });

    if (!session.url) {
      return c.html(errorPage("Checkout unavailable", "Stripe did not return a checkout URL."), 500);
    }

    return c.redirect(session.url, 303);
  });

  route.get("/checkout/success", async (c) => {
    const stripe = deps.getStripe(c.env);
    const alreadyActive = c.req.query("already_active") === "1";
    if (alreadyActive) {
      const uid = c.req.query("uid")?.trim() ?? "";
      if (!UUID_RE.test(uid)) {
        return c.html(errorPage("Purchase not completed", "Invalid uid."), 400);
      }

      const customer = await findCustomer(stripe, uid);
      if (!customer) {
        return c.html(errorPage("Purchase not completed", "No billing customer found."), 404);
      }

      const activeSubscription = await findActiveSubscription(stripe, customer.id);
      if (!activeSubscription) {
        return c.html(errorPage("Purchase not completed", "No active subscription was found."), 400);
      }

      return c.html(successPage("Your subscription is already active."));
    }

    const sessionId = c.req.query("session_id");
    if (!sessionId) {
      return c.html(errorPage("Purchase not completed", "Missing Stripe checkout session."), 400);
    }

    const session = await stripe.checkout.sessions.retrieve(sessionId);
    if (session.status !== "complete" || session.mode !== "subscription" || !session.subscription) {
      return c.html(
        errorPage("Purchase not completed", "The Stripe checkout session was not completed."),
        400,
      );
    }

    const appUserId = session.metadata?.[REVENUECAT_USER_METADATA_KEY]
      ?? session.metadata?.[LEGACY_APP_USER_METADATA_KEY]
      ?? session.client_reference_id;
    const packageId = session.metadata?.package_id;
    const plan = packageId ? planForPackageId(packageId) : null;

    if (!appUserId || !UUID_RE.test(appUserId) || !plan) {
      return c.html(errorPage("Purchase not completed", "Stripe returned incomplete purchase data."), 400);
    }

    return c.html(successPage("You're all set."));
  });

  route.get("/checkout/cancelled", async (c) => {
    return c.html(errorPage("Checkout cancelled", "No purchase was made. You can close this page and return to Grocer."));
  });

  route.get("/api/billing/portal", async (c) => {
    const uid = c.req.query("uid")?.trim() ?? "";
    if (!UUID_RE.test(uid)) {
      return c.json({ ok: false, error: "Invalid uid" }, 400);
    }

    const stripe = deps.getStripe(c.env);
    const customer = await findCustomer(stripe, uid);
    if (!customer) {
      return c.json({ ok: false, error: "No billing customer found" }, 404);
    }

    const url = new URL(c.req.url);
    const session = await stripe.billingPortal.sessions.create({
      customer: customer.id,
      return_url: url.origin,
    });

    return c.redirect(session.url, 303);
  });

  return route;
}

export const billingRoute = createBillingRoute();

export function planForPackageId(packageId: string): BillingPlan | undefined {
  const normalized = packageId.trim().toLowerCase();
  return PLANS.find((plan) =>
    plan.aliases.some((alias) => alias.toLowerCase() === normalized)
  );
}

export function externalPurchaseStorefronts(value: string | undefined): string[] {
  const parsed = (value ?? "USA")
    .split(",")
    .map((part) => part.trim().toUpperCase())
    .filter(Boolean);
  return parsed.length > 0 ? Array.from(new Set(parsed)) : ["USA"];
}

function defaultStripe(env: Env): StripeClient {
  return new Stripe(env.STRIPE_SECRET_KEY, {
    httpClient: Stripe.createFetchHttpClient(),
  });
}

function parseCheckoutParams(packageId: string | undefined, uid: string | undefined):
  | { ok: true; packageId: string; uid: string }
  | { ok: false; error: string } {
  const cleanPackageId = packageId?.trim() ?? "";
  const cleanUid = uid?.trim() ?? "";
  if (!cleanPackageId) return { ok: false, error: "Missing packageId." };
  if (!UUID_RE.test(cleanUid)) return { ok: false, error: "Invalid uid." };
  return { ok: true, packageId: cleanPackageId, uid: cleanUid };
}

async function findOrCreateCustomer(stripe: StripeClient, appUserId: string) {
  const existing = await findCustomer(stripe, appUserId);
  if (existing) return existing;
  return stripe.customers.create({
    metadata: revenueCatIdentityMetadata(appUserId),
  });
}

async function findCustomer(stripe: StripeClient, appUserId: string) {
  for (const key of [REVENUECAT_USER_METADATA_KEY, LEGACY_APP_USER_METADATA_KEY]) {
    const result = await stripe.customers.search({
      query: `metadata['${key}']:'${appUserId}'`,
      limit: 1,
    });
    if (result.data[0]) return result.data[0];
  }
  return null;
}

function revenueCatIdentityMetadata(appUserId: string): Record<string, string> {
  return {
    [REVENUECAT_USER_METADATA_KEY]: appUserId,
    [LEGACY_APP_USER_METADATA_KEY]: appUserId,
  };
}

function checkoutMetadata(appUserId: string, plan: BillingPlan): Record<string, string> {
  return {
    ...revenueCatIdentityMetadata(appUserId),
    package_id: plan.packageId,
  };
}

async function findActiveSubscription(stripe: StripeClient, customerId: string) {
  const existing = await stripe.subscriptions.list({
    customer: customerId,
    status: "all",
    limit: 100,
  });
  return existing.data.find((subscription) =>
    subscription.status === "active" || subscription.status === "trialing"
  ) ?? null;
}

function successPage(message: string): string {
  return pageShell(
    "Grocer Pro Active",
    `
      <main class="status">
        <div class="check">✓</div>
        <h1>${escapeHTML(message)}</h1>
        <p class="muted">You can close this page and return to Grocer. Access may take a few seconds to appear while RevenueCat syncs the subscription.</p>
      </main>
    `,
  );
}

function errorPage(title: string, message: string): string {
  return pageShell(
    title,
    `
      <main class="status">
        <h1>${escapeHTML(title)}</h1>
        <p class="muted">${escapeHTML(message)}</p>
      </main>
    `,
  );
}

function pageShell(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
  <title>${escapeHTML(title)}</title>
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700;800&display=swap" rel="stylesheet" />
  <style>
    :root {
      color-scheme: light dark;
      --accent: #10b981;
      --text: #18181b; --muted: #6b7280;
      --bg: #ffffff; --card: #ffffff; --line: rgba(0, 0, 0, 0.09);
      --dark-btn: #18181b; --dark-btn-text: #ffffff;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --text: #f4f4f5; --muted: #a1a1aa;
        --bg: #0b0b0c; --card: #161618; --line: rgba(255, 255, 255, 0.1);
        --dark-btn: #f4f4f5; --dark-btn-text: #0b0b0c;
      }
    }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100dvh; display: flex; flex-direction: column; background: var(--bg); color: var(--text); font-family: "Geist", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; -webkit-font-smoothing: antialiased; }

    .status { width: min(100%, 480px); background: var(--card); border: 1px solid var(--line); border-radius: 20px; padding: 32px 24px; margin: 18vh auto 0; text-align: center; }
    .status h1 { margin: 0; font-size: 24px; }
    .muted { color: var(--muted); line-height: 1.45; }
    .check { width: 54px; height: 54px; margin: 0 auto 16px; border-radius: 999px; display: grid; place-items: center; background: var(--accent); color: #fff; font-size: 30px; font-weight: 800; }
  </style>
</head>
<body>${body}</body>
</html>`;
}

function escapeHTML(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
