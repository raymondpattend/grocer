import { Effect } from "effect";
import { Hono } from "hono";
import type { Env } from "../env.js";
import { runHandler } from "../effect/http.js";
import { externalPurchaseStorefronts } from "./billing.js";

export const configRoute = new Hono<{ Bindings: Env }>();

const DEFAULT_IOS_UPDATE_URL = "https://narro.org/grocer";

function buildNumber(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const parsed = Number(value);
  return Number.isInteger(parsed) ? parsed : undefined;
}

function envNumber(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isInteger(parsed) ? parsed : fallback;
}

configRoute.get("/config/ios", (c) =>
  runHandler(
    c,
    Effect.sync(() => {
      const minimumSupportedBuild = envNumber(c.env.IOS_MIN_BUILD, 2);
      const latestBuild = envNumber(c.env.IOS_LATEST_BUILD, minimumSupportedBuild);
      const currentBuild = buildNumber(
        c.req.query("build") ?? c.req.query("currentBuild"),
      );
      const upgradeRequired =
        currentBuild !== undefined && currentBuild < minimumSupportedBuild;

      return c.json({
        minimumSupportedBuild,
        latestBuild,
        upgradeRequired,
        status: upgradeRequired ? "upgrade_required" : "ok",
        updateUrl: c.env.IOS_UPDATE_URL ?? DEFAULT_IOS_UPDATE_URL,
        features: {
          suggestions: true,
          parseList: true,
          feedback: true,
          liveActivities: true,
        },
        payments: {
          externalPurchaseStorefronts: externalPurchaseStorefronts(
            c.env.IOS_EXTERNAL_PURCHASE_STOREFRONTS,
          ),
        },
      });
    }),
  ),
);
