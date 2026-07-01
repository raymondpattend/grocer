import { Effect } from "effect";
import { Hono } from "hono";
import {
  HeartbeatRequestSchema,
  ListActivityRequestSchema,
} from "@grocer/shared";
import type { Env } from "../env.js";
import { decodeJsonBody } from "../effect/body.js";
import { runGuard, runHandler } from "../effect/http.js";
import { fromPromise } from "../effect/interop.js";
import { authenticateSignedRequest, enforceRateLimit } from "../lib/signing.js";
import {
  disableHouseholdRegistrationsExceptMembers,
  insertListActivity,
  markDeviceOpened,
} from "../db/liveActivityTokens.js";

export const retentionRoute = new Hono<{ Bindings: Env }>();

// Same signing + rate limit as the Live Activity endpoints (register scope).
retentionRoute.use("/retention/*", async (c, next) => {
  const rejection = await runGuard(
    c,
    Effect.gen(function* () {
      yield* authenticateSignedRequest(c);
      yield* enforceRateLimit(c, "register", 90, 60);
    }),
  );
  if (rejection) return rejection;
  await next();
});

// ---------------------------------------------------------------------------
// POST /retention/heartbeat
// The app opened — stamp last_opened_at so the cron knows the user is active.
// ---------------------------------------------------------------------------
retentionRoute.post("/retention/heartbeat", (c) =>
  runHandler(
    c,
    Effect.gen(function* () {
      const data = yield* decodeJsonBody(c, HeartbeatRequestSchema);

      yield* fromPromise(() =>
        markDeviceOpened(c.env.DB, {
          deviceId: data.deviceId,
          tzOffsetMinutes: data.tzOffsetMinutes,
        }),
      );

      return c.json({ ok: true });
    }),
  ),
);

// ---------------------------------------------------------------------------
// POST /retention/activity
// The local member added items to a shared list — record it so other members
// can be told "N new items" if they later go inactive.
// ---------------------------------------------------------------------------
retentionRoute.post("/retention/activity", (c) =>
  runHandler(
    c,
    Effect.gen(function* () {
      const data = yield* decodeJsonBody(c, ListActivityRequestSchema);

      const disabled = yield* fromPromise(() =>
        disableHouseholdRegistrationsExceptMembers(
          c.env.DB,
          data.householdId,
          data.recipientMemberIds,
        ),
      );
      if (disabled > 0) {
        console.log(
          `[retention] disabled stale household registrations ` +
            `household=${data.householdId} disabledRows=${disabled}`,
        );
      }

      yield* fromPromise(() =>
        insertListActivity(c.env.DB, {
          householdId: data.householdId,
          actorMemberId: data.actorMemberId,
          actorDisplayName: data.actorDisplayName,
          itemCount: data.itemCount,
        }),
      );

      return c.json({ ok: true });
    }),
  ),
);
