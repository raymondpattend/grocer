import { describe, expect, it, vi } from "vitest";
import {
  createBillingRoute,
  planForPackageId,
} from "../src/routes/billing.js";

const UID = "123e4567-e89b-42d3-a456-426614174000";

const env = {
  STRIPE_SECRET_KEY: "sk_test_123",
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
    checkout: {
      sessions: {
        create: vi.fn(async () => ({
          id: "cs_new",
          url: "https://checkout.stripe.test/session",
        })),
        retrieve: vi.fn(async () => ({
          id: "cs_done",
          status: "complete",
          mode: "subscription",
          client_reference_id: UID,
          subscription: "sub_new",
          metadata: {
            user_id: UID,
            app_user_id: UID,
            package_id: "$rc_monthly",
          },
        })),
      },
    },
    subscriptions: {
      list: vi.fn(async () => ({ data: [] })),
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
    expect(stripe.checkout.sessions.create).not.toHaveBeenCalled();
  });

  it("maps every Grocer plan to its Stripe price", async () => {
    const cases = [
      ["$rc_annual", "price_annual", "$rc_annual"],
      ["$rc_three_month", "price_quarterly", "$rc_three_month"],
      ["$rc_monthly", "price_monthly", "$rc_monthly"],
      ["grocer_pro_subscription_annual_1", "price_annual", "$rc_annual"],
      ["grocer_pro_subscription_quarterly_1", "price_quarterly", "$rc_three_month"],
      ["grocer_pro_subscription_monthly_1", "price_monthly", "$rc_monthly"],
    ];

    for (const [packageId, priceId, canonicalPackageId] of cases) {
      const stripe = setupStripe();
      const response = await routeFor(stripe).request(
        `/checkout?packageId=${encodeURIComponent(packageId)}&uid=${UID}`,
        {},
        env,
      );

      expect(response.status).toBe(303);
      expect(response.headers.get("location")).toBe("https://checkout.stripe.test/session");
      expect(stripe.checkout.sessions.create).toHaveBeenCalledWith(
        expect.objectContaining({
          mode: "subscription",
          customer: "cus_new",
          client_reference_id: UID,
          line_items: [{ price: priceId, quantity: 1 }],
          payment_method_types: ["card"],
          metadata: {
            user_id: UID,
            app_user_id: UID,
            package_id: canonicalPackageId,
          },
          subscription_data: {
            metadata: {
              user_id: UID,
              app_user_id: UID,
              package_id: canonicalPackageId,
            },
          },
          success_url: expect.stringContaining("/checkout/success?session_id={CHECKOUT_SESSION_ID}"),
          cancel_url: expect.stringContaining("/checkout/cancelled"),
        }),
      );
    }
  });

  it("reuses an existing customer and stores RevenueCat identity on the Checkout Session", async () => {
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
    expect(stripe.checkout.sessions.create).toHaveBeenCalledWith(
      expect.objectContaining({
        customer: "cus_existing",
        metadata: {
          user_id: UID,
          app_user_id: UID,
          package_id: "$rc_monthly",
        },
      }),
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

  it("redirects existing active subscribers without creating another Checkout Session", async () => {
    const stripe = setupStripe({
      customers: {
        search: vi.fn(async () => ({ data: [{ id: "cus_existing" }] })),
        create: vi.fn(),
      },
      subscriptions: {
        list: vi.fn(async () => ({ data: [{ id: "sub_existing", status: "active" }] })),
      },
      checkout: {
        sessions: {
          create: vi.fn(),
          retrieve: vi.fn(),
        },
      },
    });

    const response = await routeFor(stripe).request(
      `/checkout?packageId=%24rc_monthly&uid=${UID}`,
      {},
      env,
    );

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toContain("/checkout/success?already_active=1");
    expect(stripe.checkout.sessions.create).not.toHaveBeenCalled();
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

  it("rejects incomplete Checkout Sessions", async () => {
    const stripe = setupStripe({
      checkout: {
        sessions: {
          create: vi.fn(),
          retrieve: vi.fn(async () => ({
            id: "cs_open",
            status: "open",
            mode: "subscription",
            metadata: {
              user_id: UID,
              app_user_id: UID,
              package_id: "$rc_monthly",
            },
          })),
        },
      },
    });

    const response = await routeFor(stripe).request(
      "/checkout/success?session_id=cs_open",
      {},
      env,
    );

    expect(response.status).toBe(400);
  });

  it("accepts a completed Checkout Session with RevenueCat user_id and package metadata", async () => {
    const stripe = setupStripe();

    const response = await routeFor(stripe).request(
      "/checkout/success?session_id=cs_done",
      {},
      env,
    );
    const html = await response.text();

    expect(response.status).toBe(200);
    expect(html).toContain("You're all set.");
    expect(stripe.checkout.sessions.retrieve).toHaveBeenCalledWith("cs_done");
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
