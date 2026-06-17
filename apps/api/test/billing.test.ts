import { describe, expect, it, vi } from "vitest";
import {
  createBillingRoute,
  planForPackageId,
} from "../src/routes/billing.js";

const UID = "123e4567-e89b-42d3-a456-426614174000";

const env = {
  STRIPE_SECRET_KEY: "sk_test_123",
  STRIPE_PUBLISHABLE_KEY: "pk_test_123",
  STRIPE_PRICE_ANNUAL: "price_annual",
  STRIPE_PRICE_QUARTERLY: "price_quarterly",
  STRIPE_PRICE_MONTHLY: "price_monthly",
};

function setupStripe(overrides: Record<string, unknown> = {}) {
  const stripe = {
    customers: {
      search: vi.fn(async () => ({ data: [] })),
      create: vi.fn(async () => ({ id: "cus_new" })),
    },
    prices: {
      retrieve: vi.fn(async () => ({
        id: "price_monthly",
        unit_amount: 499,
        currency: "usd",
        recurring: { interval: "month", interval_count: 1 },
      })),
    },
    setupIntents: {
      create: vi.fn(async () => ({
        id: "seti_new",
        client_secret: "seti_new_secret",
      })),
      retrieve: vi.fn(async () => ({
        id: "seti_done",
        status: "succeeded",
        customer: "cus_new",
        payment_method: "pm_card",
        metadata: {
          user_id: UID,
          app_user_id: UID,
          package_id: "$rc_monthly",
        },
      })),
    },
    subscriptions: {
      list: vi.fn(async () => ({ data: [] })),
      create: vi.fn(async () => ({ id: "sub_new", status: "active" })),
    },
    billingPortal: {
      sessions: {
        create: vi.fn(async () => ({ url: "https://billing.stripe.test/session" })),
      },
    },
    ...overrides,
  };
  return stripe;
}

function routeFor(stripe = setupStripe()) {
  return createBillingRoute({
    getStripe: () => stripe as never,
  });
}

describe("billing checkout", () => {
  it("rejects invalid checkout params before calling Stripe", async () => {
    const stripe = setupStripe();
    const response = await routeFor(stripe).request(
      "/checkout?packageId=%24rc_monthly&uid=not-a-uuid",
      {},
      env,
    );

    expect(response.status).toBe(400);
    expect(stripe.setupIntents.create).not.toHaveBeenCalled();
  });

  it("renders a custom Elements checkout page seeded with a SetupIntent secret", async () => {
    const stripe = setupStripe();
    const response = await routeFor(stripe).request(
      `/checkout?packageId=%24rc_monthly&uid=${UID}`,
      {},
      env,
    );
    const html = await response.text();

    expect(response.status).toBe(200);
    expect(html).toContain("Subscribe to Grocer Pro");
    expect(html).toContain("seti_new_secret");
    expect(html).toContain("pk_test_123");
    expect(html).toContain("js.stripe.com/v3");
    expect(html).toContain("$4.99");
    expect(html).toContain("availablepaymentmethodschange");
    expect(html).toContain("paymentFailed");
  });

  it("seeds the SetupIntent with the RevenueCat identity and plan metadata", async () => {
    const cases = [
      ["$rc_annual", "$rc_annual"],
      ["$rc_three_month", "$rc_three_month"],
      ["$rc_monthly", "$rc_monthly"],
      ["grocer_pro_subscription_annual_1", "$rc_annual"],
      ["grocer_pro_subscription_quarterly_1", "$rc_three_month"],
      ["grocer_pro_subscription_monthly_1", "$rc_monthly"],
    ];

    for (const [packageId, canonicalPackageId] of cases) {
      const stripe = setupStripe();
      const response = await routeFor(stripe).request(
        `/checkout?packageId=${encodeURIComponent(packageId)}&uid=${UID}`,
        {},
        env,
      );

      expect(response.status).toBe(200);
      expect(stripe.setupIntents.create).toHaveBeenCalledWith(
        expect.objectContaining({
          customer: "cus_new",
          usage: "off_session",
          payment_method_types: ["card"],
          metadata: {
            user_id: UID,
            app_user_id: UID,
            package_id: canonicalPackageId,
          },
        }),
      );
    }
  });

  it("returns 500 when the publishable key is missing", async () => {
    const stripe = setupStripe();
    const response = await routeFor(stripe).request(
      `/checkout?packageId=%24rc_monthly&uid=${UID}`,
      {},
      { ...env, STRIPE_PUBLISHABLE_KEY: "" },
    );

    expect(response.status).toBe(500);
    expect(stripe.setupIntents.create).not.toHaveBeenCalled();
  });

  it("reuses an existing customer", async () => {
    const stripe = setupStripe({
      customers: {
        search: vi.fn(async () => ({ data: [{ id: "cus_existing" }] })),
        create: vi.fn(),
      },
    });

    await routeFor(stripe).request(
      `/checkout?packageId=%24rc_monthly&uid=${UID}`,
      {},
      env,
    );

    expect(stripe.customers.create).not.toHaveBeenCalled();
    expect(stripe.setupIntents.create).toHaveBeenCalledWith(
      expect.objectContaining({ customer: "cus_existing" }),
    );
  });

  it("creates a customer when no Stripe customer has the RevenueCat identity", async () => {
    const stripe = setupStripe();

    await routeFor(stripe).request(
      `/checkout?packageId=%24rc_monthly&uid=${UID}`,
      {},
      env,
    );

    expect(stripe.customers.create).toHaveBeenCalledWith({
      metadata: {
        user_id: UID,
        app_user_id: UID,
      },
    });
  });

  it("redirects existing active subscribers without creating a SetupIntent", async () => {
    const stripe = setupStripe({
      customers: {
        search: vi.fn(async () => ({ data: [{ id: "cus_existing" }] })),
        create: vi.fn(),
      },
      subscriptions: {
        list: vi.fn(async () => ({ data: [{ id: "sub_existing", status: "active" }] })),
        create: vi.fn(),
      },
    });

    const response = await routeFor(stripe).request(
      `/checkout?packageId=%24rc_monthly&uid=${UID}`,
      {},
      env,
    );

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toContain("/checkout/success?already_active=1");
    expect(stripe.setupIntents.create).not.toHaveBeenCalled();
  });
});

describe("billing success", () => {
  it("confirms already-active subscribers after verifying the customer subscription", async () => {
    const stripe = setupStripe({
      customers: {
        search: vi.fn(async () => ({ data: [{ id: "cus_existing" }] })),
        create: vi.fn(),
      },
      subscriptions: {
        list: vi.fn(async () => ({ data: [{ id: "sub_existing", status: "active" }] })),
        create: vi.fn(),
      },
    });

    const response = await routeFor(stripe).request(
      `/checkout/success?already_active=1&uid=${UID}`,
      {},
      env,
    );
    const html = await response.text();

    expect(response.status).toBe(200);
    expect(html).toContain("already active");
  });

  it("rejects a SetupIntent that has not succeeded", async () => {
    const stripe = setupStripe({
      setupIntents: {
        create: vi.fn(),
        retrieve: vi.fn(async () => ({
          id: "seti_open",
          status: "requires_payment_method",
          customer: "cus_new",
          payment_method: null,
          metadata: { user_id: UID, app_user_id: UID, package_id: "$rc_monthly" },
        })),
      },
    });

    const response = await routeFor(stripe).request(
      "/checkout/success?setup_intent=seti_open&redirect_status=succeeded",
      {},
      env,
    );

    expect(response.status).toBe(400);
    expect(stripe.subscriptions.create).not.toHaveBeenCalled();
  });

  it("rejects a failed redirect status without touching Stripe", async () => {
    const stripe = setupStripe();

    const response = await routeFor(stripe).request(
      "/checkout/success?setup_intent=seti_done&redirect_status=failed",
      {},
      env,
    );

    expect(response.status).toBe(400);
    expect(stripe.setupIntents.retrieve).not.toHaveBeenCalled();
  });

  it("creates the subscription from a succeeded SetupIntent and confirms success", async () => {
    const stripe = setupStripe();

    const response = await routeFor(stripe).request(
      "/checkout/success?setup_intent=seti_done&redirect_status=succeeded",
      {},
      env,
    );
    const html = await response.text();

    expect(response.status).toBe(200);
    expect(html).toContain("You're all set.");
    expect(stripe.subscriptions.create).toHaveBeenCalledWith(
      expect.objectContaining({
        customer: "cus_new",
        items: [{ price: "price_monthly" }],
        default_payment_method: "pm_card",
        metadata: {
          user_id: UID,
          app_user_id: UID,
          package_id: "$rc_monthly",
        },
      }),
    );
  });

  it("is idempotent when an active subscription already exists", async () => {
    const stripe = setupStripe({
      subscriptions: {
        list: vi.fn(async () => ({ data: [{ id: "sub_existing", status: "active" }] })),
        create: vi.fn(),
      },
    });

    const response = await routeFor(stripe).request(
      "/checkout/success?setup_intent=seti_done&redirect_status=succeeded",
      {},
      env,
    );

    expect(response.status).toBe(200);
    expect(stripe.subscriptions.create).not.toHaveBeenCalled();
  });
});

describe("billing portal", () => {
  it("returns 404 when a web billing customer cannot be found", async () => {
    const response = await routeFor().request(
      `/api/billing/portal?uid=${UID}`,
      {},
      env,
    );

    expect(response.status).toBe(404);
    await expect(response.json()).resolves.toMatchObject({
      ok: false,
      error: "No billing customer found",
    });
  });

  it("redirects to the Stripe billing portal for existing customers", async () => {
    const stripe = setupStripe({
      customers: {
        search: vi.fn(async () => ({ data: [{ id: "cus_existing" }] })),
        create: vi.fn(),
      },
    });

    const response = await routeFor(stripe).request(
      `/api/billing/portal?uid=${UID}`,
      {},
      env,
    );

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe("https://billing.stripe.test/session");
  });
});

describe("planForPackageId", () => {
  it("normalizes known package and product identifiers", () => {
    expect(planForPackageId("$rc_annual")?.priceEnv).toBe("STRIPE_PRICE_ANNUAL");
    expect(planForPackageId("grocer_pro_subscription_quarterly_1")?.priceEnv).toBe("STRIPE_PRICE_QUARTERLY");
    expect(planForPackageId("missing")).toBeUndefined();
  });
});
