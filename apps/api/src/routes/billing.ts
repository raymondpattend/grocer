import { Hono } from "hono";
import Stripe from "stripe";
import type { Env } from "../env.js";
import { APP_ICON_DATA_URI } from "./appIcon.js";

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
  /**
   * Length of an introductory free trial, in days, applied at subscription
   * creation *only when the client requests the trial variant* (`trial=1`).
   * Set on plans eligible for an A/B-test trial; the same plan bills with no
   * trial when the flag is absent. Omit for plans that never offer a trial.
   */
  trialDays?: number;
};

type PriceSummary = {
  amount: number;
  currency: string;
  interval: string;
  intervalCount: number;
  formatted: string;
  cadence: string;
  intervalLabel: string;
};

const PLANS: BillingPlan[] = [
  {
    key: "annual",
    title: "Annual",
    packageId: "$rc_annual",
    priceEnv: "STRIPE_PRICE_ANNUAL",
    // Trial length applied only when the client signals the trial variant
    // (`trial=1`), e.g. the `trial_3day_annual_only` RevenueCat A/B-test
    // offering. The control annual offering omits the flag and bills with no
    // trial. The trial is applied at subscription creation, not baked into the
    // Stripe price, so both variants share STRIPE_PRICE_ANNUAL.
    trialDays: 3,
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

  // Renders a custom, Grocer-branded checkout page backed by a Stripe
  // SetupIntent. The Payment Element collects a card, `confirmSetup` saves it,
  // and the subscription is created on the success page from the succeeded
  // SetupIntent — so we never ship users to Stripe's hosted checkout UI.
  route.get("/checkout", async (c) => {
    const input = parseCheckoutParams(c.req.query("packageId"), c.req.query("uid"));
    if (!input.ok) {
      return c.html(errorPage("Checkout unavailable", input.error), 400);
    }

    const plan = planForPackageId(input.packageId);
    if (!plan) {
      return c.html(errorPage("Plan unavailable", "This plan is not available for web checkout."), 400);
    }

    // The trial variant only earns a trial if the resolved plan is eligible
    // (has a configured trialDays), so an unexpected `trial=1` can't conjure a
    // trial on a plan that should never have one.
    const wantsTrial = c.req.query("trial") === "1" && plan.trialDays != null;

    const priceId = c.env[plan.priceEnv]?.trim();
    if (!priceId) {
      return c.html(errorPage("Checkout unavailable", "This plan is not configured yet."), 500);
    }

    const publishableKey = c.env.STRIPE_PUBLISHABLE_KEY?.trim();
    if (!publishableKey) {
      return c.html(errorPage("Checkout unavailable", "Payments are not configured yet."), 500);
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

    const price = await stripe.prices.retrieve(priceId);
    // Restrict to cards only — this keeps the bank/ACH option out of the
    // Payment Element while still allowing Apple Pay (a card-backed wallet)
    // through the Express Checkout Element.
    const setupIntent = await stripe.setupIntents.create({
      customer: customer.id,
      usage: "off_session",
      payment_method_types: ["card"],
      metadata: checkoutMetadata(input.uid, plan, wantsTrial),
    });

    if (!setupIntent.client_secret) {
      return c.html(errorPage("Checkout unavailable", "Stripe did not return a checkout secret."), 500);
    }

    return c.html(
      checkoutPage({
        publishableKey,
        clientSecret: setupIntent.client_secret,
        plan,
        price: priceSummary(price),
        uid: input.uid,
        origin: url.origin,
        trialDays: wantsTrial ? plan.trialDays ?? 0 : 0,
      }),
    );
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

    const setupIntentId = c.req.query("setup_intent");
    const redirectStatus = c.req.query("redirect_status");
    if (!setupIntentId) {
      return c.html(errorPage("Purchase not completed", "Missing Stripe setup details."), 400);
    }
    if (redirectStatus && redirectStatus !== "succeeded") {
      return c.html(errorPage("Purchase not completed", "The payment was not completed."), 400);
    }

    const result = await createSubscriptionFromSetupIntent(stripe, c.env, setupIntentId);
    if (!result.ok) {
      return c.html(errorPage("Purchase not completed", result.error), 400);
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

function checkoutMetadata(
  appUserId: string,
  plan: BillingPlan,
  wantsTrial = false,
): Record<string, string> {
  return {
    ...revenueCatIdentityMetadata(appUserId),
    package_id: plan.packageId,
    // Round-trips the trial variant through the SetupIntent so the subscription,
    // created later on the success page, applies the matching trial.
    ...(wantsTrial ? { trial: "1" } : {}),
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

/// Creates the subscription from a succeeded SetupIntent. Idempotent: if the
/// customer already has an active/trialing subscription (e.g. the success page
/// is reloaded) it is a no-op.
async function createSubscriptionFromSetupIntent(
  stripe: StripeClient,
  env: Env,
  setupIntentId: string,
): Promise<{ ok: true } | { ok: false; error: string }> {
  const setupIntent = await stripe.setupIntents.retrieve(setupIntentId);
  if (setupIntent.status !== "succeeded") {
    return { ok: false, error: "The Stripe payment setup was not completed." };
  }

  const customerId = idOf(setupIntent.customer);
  const paymentMethodId = idOf(setupIntent.payment_method);
  const packageId = setupIntent.metadata?.package_id;
  const appUserId = setupIntent.metadata?.[REVENUECAT_USER_METADATA_KEY]
    ?? setupIntent.metadata?.[LEGACY_APP_USER_METADATA_KEY];
  const plan = packageId ? planForPackageId(packageId) : undefined;
  const priceId = plan ? env[plan.priceEnv]?.trim() : undefined;

  if (!customerId || !paymentMethodId || !plan || !priceId
    || !appUserId || !UUID_RE.test(appUserId)) {
    return { ok: false, error: "Stripe returned incomplete purchase data." };
  }

  const wantsTrial = setupIntent.metadata?.trial === "1" && plan.trialDays != null;

  const existing = await findActiveSubscription(stripe, customerId);
  if (existing) return { ok: true };

  await stripe.subscriptions.create({
    customer: customerId,
    items: [{ price: priceId }],
    default_payment_method: paymentMethodId,
    ...(wantsTrial ? { trial_period_days: plan.trialDays } : {}),
    metadata: checkoutMetadata(appUserId, plan, wantsTrial),
  });

  return { ok: true };
}

function idOf(value: string | { id: string } | null | undefined): string | undefined {
  if (!value) return undefined;
  return typeof value === "string" ? value : value.id;
}

function priceSummary(price: Stripe.Price): PriceSummary {
  const amount = price.unit_amount ?? 0;
  const currency = price.currency ?? "usd";
  const interval = price.recurring?.interval ?? "month";
  const intervalCount = price.recurring?.interval_count ?? 1;
  return {
    amount,
    currency,
    interval,
    intervalCount,
    formatted: formatMoney(amount, currency),
    cadence: formatCadence(interval, intervalCount),
    intervalLabel: formatIntervalLabel(interval, intervalCount),
  };
}

function formatMoney(amount: number, currency: string): string {
  try {
    return new Intl.NumberFormat("en-US", {
      style: "currency",
      currency: currency.toUpperCase(),
    }).format(amount / 100);
  } catch {
    return `$${(amount / 100).toFixed(2)}`;
  }
}

function formatCadence(interval: string, count: number): string {
  return count === 1 ? interval : `${count} ${interval}s`;
}

function formatIntervalLabel(interval: string, count: number): string {
  if (count === 1) {
    return interval === "year" ? "annually" : interval === "month" ? "monthly" : `every ${interval}`;
  }
  return `every ${count} ${interval}s`;
}

type CheckoutPageInput = {
  publishableKey: string;
  clientSecret: string;
  plan: BillingPlan;
  price: PriceSummary;
  uid: string;
  origin: string;
  /** Resolved trial length to display (0 unless the trial variant was requested). */
  trialDays: number;
};

function checkoutPage(input: CheckoutPageInput): string {
  const { price } = input;
  const trialDays = input.trialDays;
  // The trial converts to a paid renewal trialDays after the subscription is
  // created (which happens right after card confirmation), so today + trialDays
  // is the date the customer is first charged the normal price.
  const renewsOn = trialDays > 0
    ? new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric" })
        .format(new Date(Date.now() + trialDays * 24 * 60 * 60 * 1000))
    : "";
  const config = {
    publishableKey: input.publishableKey,
    clientSecret: input.clientSecret,
    returnUrl: `${input.origin}/checkout/success?uid=${encodeURIComponent(input.uid)}`,
    origin: input.origin,
    amount: price.amount,
    currency: price.currency,
    interval: price.interval,
    intervalCount: price.intervalCount,
    intervalLabel: price.intervalLabel,
    trialDays,
  };

  const body = `
    <main class="checkout">
      <header class="brand">
        <img class="brand-logo" src="${APP_ICON_DATA_URI}" alt="Grocer" width="36" height="36" />
        <span class="brand-name">Grocer</span>
      </header>

      <h1 class="title">Subscribe to Pro</h1>

      <section class="summary">
        ${trialDays > 0
          ? `<div class="summary-row">
          <span class="summary-label">Free trial</span>
          <span class="summary-price">${trialDays} days</span>
        </div>
        <div class="summary-row">
          <span class="summary-label">Due today</span>
          <span class="summary-price">${escapeHTML(formatMoney(0, price.currency))}</span>
        </div>
        <div class="summary-row">
          <span class="summary-label">Renews ${escapeHTML(renewsOn)}</span>
          <span class="summary-price">${escapeHTML(price.formatted)}<span class="cadence">/${escapeHTML(price.cadence)}</span></span>
        </div>`
          : `<div class="summary-row">
          <span class="summary-label">Billed today</span>
          <span class="summary-price">${escapeHTML(price.formatted)}<span class="cadence">/${escapeHTML(price.cadence)}</span></span>
        </div>`}
      </section>

      <div id="express-wrap" class="express">
        <div id="express-checkout-element"></div>
      </div>

      <button id="pay-with-card" type="button" class="card-toggle">Pay with card</button>

      <div id="card-section" class="hidden">
        <div id="card-divider" class="divider"><span>or pay with card</span></div>
        <form id="payment-form" class="card">
          <div id="payment-element"></div>
          <p id="error-message" class="error" role="alert"></p>
          <button id="submit" type="submit" class="pay">
            <span id="button-text">${trialDays > 0 ? "Start free trial" : "Subscribe"}</span>
            <span id="spinner" class="spinner hidden"></span>
          </button>
        </form>
      </div>

      <p class="fineprint">
        ${trialDays > 0
          ? `Your free trial lasts ${trialDays} days. After it ends you'll be charged ${escapeHTML(price.formatted)} plus applicable taxes, and your subscription renews every ${escapeHTML(price.cadence)} unless you turn off auto-renewal in your Grocer settings before the renewal date.`
          : `You'll be charged ${escapeHTML(price.formatted)} plus applicable taxes. Your subscription renews every ${escapeHTML(price.cadence)} unless you turn off auto-renewal in your Grocer settings before the renewal date.`}
      </p>

      <footer class="footer">© ${new Date().getFullYear()} Narro. All rights reserved.</footer>
    </main>

    <script src="https://js.stripe.com/v3/"></script>
    <script>
      (function () {
        var config = ${JSON.stringify(config)};
        var stripe = Stripe(config.publishableKey);

        var darkQuery = window.matchMedia
          ? window.matchMedia("(prefers-color-scheme: dark)")
          : { matches: false };

        function makeAppearance() {
          var dark = darkQuery.matches;
          return {
            theme: dark ? "night" : "flat",
            variables: {
              colorPrimary: "#10b981",
              colorBackground: dark ? "#161618" : "#ffffff",
              colorText: dark ? "#f4f4f5" : "#18181b",
              colorDanger: "#ef4444",
              fontFamily: 'Geist, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
              borderRadius: "12px",
              spacingUnit: "4px",
            },
            rules: {
              ".Input": {
                border: "1px solid " + (dark ? "rgba(255,255,255,0.12)" : "#e5e7eb"),
                boxShadow: "none",
                padding: "12px",
                backgroundColor: dark ? "#1e1e20" : "#fafafa",
              },
              ".Input:focus": {
                border: "1px solid #10b981",
                boxShadow: "0 0 0 1px #10b981",
                backgroundColor: dark ? "#161618" : "#ffffff",
              },
              ".Label": { fontWeight: "500" },
            },
          };
        }

        var elements = stripe.elements({
          clientSecret: config.clientSecret,
          appearance: makeAppearance(),
        });

        function onMediaChange(query, handler) {
          if (query.addEventListener) query.addEventListener("change", handler);
          else if (query.addListener) query.addListener(handler);
        }

        onMediaChange(darkQuery, function () {
          elements.update({ appearance: makeAppearance() });
        });

        var errorMessage = document.getElementById("error-message");
        var submitButton = document.getElementById("submit");
        var buttonText = document.getElementById("button-text");
        var spinner = document.getElementById("spinner");
        var payWithCard = document.getElementById("pay-with-card");
        var cardSection = document.getElementById("card-section");
        var cardDivider = document.getElementById("card-divider");
        var expressWrap = document.getElementById("express-wrap");

        function setLoading(loading) {
          submitButton.disabled = loading;
          spinner.classList.toggle("hidden", !loading);
          buttonText.classList.toggle("hidden", loading);
        }

        function showError(message) {
          errorMessage.textContent = message || "Something went wrong. Please try again.";
        }

        function confirm(expressEvent) {
          errorMessage.textContent = "";
          return stripe
            .confirmSetup({
              elements: elements,
              confirmParams: { return_url: config.returnUrl },
            })
            .then(function (result) {
              if (result.error) {
                if (expressEvent && expressEvent.paymentFailed) {
                  expressEvent.paymentFailed({ reason: "fail" });
                }
                showError(result.error.message);
              }
              return result;
            });
        }

        // Card payment element (mounted eagerly so it's ready when revealed).
        var paymentElement = elements.create("payment", {
          layout: { type: "accordion", defaultCollapsed: false, radios: false, spacedAccordionItems: false },
        });
        paymentElement.mount("#payment-element");

        document.getElementById("payment-form").addEventListener("submit", function (event) {
          event.preventDefault();
          setLoading(true);
          confirm().then(function (result) {
            if (result.error) setLoading(false);
          });
        });

        function revealCardForm(withDivider) {
          cardSection.classList.remove("hidden");
          cardDivider.classList.toggle("hidden", !withDivider);
          payWithCard.classList.add("hidden");
        }

        payWithCard.addEventListener("click", function () {
          revealCardForm(true);
        });

        // Express Checkout (Apple Pay).
        var expressCheckout = elements.create("expressCheckout", {
          buttonType: { applePay: "plain" },
          buttonTheme: { applePay: darkQuery.matches ? "white" : "black" },
          buttonHeight: 52,
          paymentMethods: { applePay: "always", googlePay: "never", link: "never" },
          applePay: {
            recurringPaymentRequest: {
              paymentDescription: "Grocer Pro " + config.intervalLabel + " subscription",
              managementURL: config.origin + "/checkout/success",
              regularBilling: {
                amount: config.amount,
                label: "Grocer Pro (" + config.intervalLabel + ")",
                recurringPaymentIntervalUnit: config.interval,
                recurringPaymentIntervalCount: config.intervalCount,
              },
              trialBilling: config.trialDays > 0
                ? {
                    amount: 0,
                    label: config.trialDays + "-day free trial",
                    recurringPaymentIntervalUnit: "day",
                    recurringPaymentIntervalCount: config.trialDays,
                  }
                : undefined,
            },
          },
        });

        expressCheckout.on("confirm", function (event) {
          confirm(event);
        });

        function syncExpressAvailability(event) {
          var methods = event && (event.paymentMethods || event.availablePaymentMethods);
          if (!methods) {
            // No Apple Pay available — fall back to the card form, no divider.
            expressWrap.classList.add("hidden");
            payWithCard.classList.add("hidden");
            revealCardForm(false);
          }
        }

        expressCheckout.on("availablepaymentmethodschange", syncExpressAvailability);
        expressCheckout.on("ready", syncExpressAvailability);

        expressCheckout.on("loaderror", function () {
          expressWrap.classList.add("hidden");
          payWithCard.classList.add("hidden");
          revealCardForm(false);
        });

        expressCheckout.mount("#express-checkout-element");
      })();
    </script>
  `;

  return checkoutShell("Subscribe to Grocer Pro", body);
}

function successPage(message: string): string {
  return pageShell(
    "Grocer Pro Active",
    `
      <main class="status">
        <div class="check">✓</div>
        <h1>${escapeHTML(message)}</h1>
        <p class="muted">Thank you for subscribing to Grocer Pro, you may now close this page.</p>
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
  <link rel="icon" href="${APP_ICON_DATA_URI}" type="image/png" />
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

// Checkout inherits the WebView's current color scheme, and the Swift wrapper
// uses the same page background so safe areas blend with the web content.
function checkoutShell(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover" />
  <title>${escapeHTML(title)}</title>
  <link rel="icon" href="${APP_ICON_DATA_URI}" type="image/png" />
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700;800&display=swap" rel="stylesheet" />
  <style>
    :root {
      color-scheme: light dark;
      --accent: #10b981;
      --page: #f6f6f7; --text: #18181b; --muted: #6b7280;
      --card: #ffffff; --line: rgba(0, 0, 0, 0.08);
      --dark-btn: #18181b; --dark-btn-text: #ffffff;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --page: #0b0b0c; --text: #f4f4f5; --muted: #a1a1aa;
        --card: #161618; --line: rgba(255, 255, 255, 0.1);
        --dark-btn: #f4f4f5; --dark-btn-text: #0b0b0c;
      }
    }
    * { box-sizing: border-box; }
    html, body { background: var(--page); }
    body {
      margin: 0; min-height: 100dvh; color: var(--text);
      font-family: "Geist", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      -webkit-font-smoothing: antialiased;
      -webkit-text-size-adjust: 100%; touch-action: manipulation;
    }
    .checkout {
      width: min(100%, 460px);
      margin: 0 auto;
      padding: max(env(safe-area-inset-top), 16px) 24px calc(env(safe-area-inset-bottom) + 28px);
      display: flex; flex-direction: column;
    }
    .brand { display: flex; align-items: center; justify-content: center; gap: 10px; padding: 14px 0 22px; }
    .brand-logo { border-radius: 22%; display: block; }
    .brand-name { font-size: 30px; font-weight: 800; letter-spacing: -0.02em; line-height: 1; }

    .title { margin: 8px 0 22px; text-align: center; font-size: 22px; font-weight: 700; }

    .summary {
      background: var(--card); border: 1px solid var(--line); border-radius: 16px;
      padding: 2px 20px; box-shadow: 0 1px 2px rgba(0, 0, 0, 0.04); margin-bottom: 8px;
    }
    .summary-row { display: flex; align-items: center; justify-content: space-between; padding: 16px 0; }
    .summary-label { font-weight: 600; }
    .summary-price { font-weight: 700; }
    .cadence { color: var(--muted); font-weight: 500; }

    .express { margin-top: 12px; min-height: 0; }

    .card-toggle {
      margin: 16px auto 0; padding: 8px; border: none; background: none; cursor: pointer;
      font-family: inherit; font-size: 15px; font-weight: 600; color: var(--accent);
      text-decoration: underline; text-underline-offset: 2px;
    }

    .divider { display: flex; align-items: center; gap: 12px; margin: 18px 2px; }
    .divider::before, .divider::after { content: ""; flex: 1; height: 1px; background: var(--line); }
    .divider span { font-size: 14px; color: var(--muted); }

    .card {
      background: var(--card); border: 1px solid var(--line); border-radius: 16px;
      padding: 20px; margin-top: 12px; box-shadow: 0 1px 2px rgba(0, 0, 0, 0.04);
    }
    .error { margin: 12px 0 0; text-align: center; color: #ef4444; font-size: 14px; }
    .error:empty { margin: 0; }

    .pay {
      margin-top: 20px; width: 100%; min-height: 52px; border: none; cursor: pointer;
      border-radius: 14px; background: var(--dark-btn); color: var(--dark-btn-text);
      font-family: inherit; font-size: 16px; font-weight: 600;
      display: flex; align-items: center; justify-content: center; gap: 8px;
      transition: opacity 0.15s ease;
    }
    .pay:disabled { opacity: 0.55; cursor: default; }

    .fineprint { margin: 24px 6px 0; text-align: center; font-size: 11px; line-height: 1.55; color: var(--muted); }
    .footer { margin-top: 20px; text-align: center; font-size: 11px; color: var(--muted); opacity: 0.75; }

    .spinner {
      width: 18px; height: 18px; border-radius: 999px;
      border: 2px solid rgba(127, 127, 127, 0.4); border-top-color: var(--dark-btn-text);
      animation: spin 0.7s linear infinite;
    }
    .hidden { display: none; }
    @keyframes spin { to { transform: rotate(360deg); } }
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
