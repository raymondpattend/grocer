import { Hono } from "hono";
import {
  HeartbeatRequestSchema,
  ListActivityRequestSchema,
} from "@grocer/shared";
import type { Env } from "../env.js";
import { parseBody } from "../lib/validate.js";
import { authenticateSignedRequest, enforceRateLimit } from "../lib/signing.js";
import {
  disableHouseholdRegistrationsExceptMembers,
  insertListActivity,
  markDeviceOpened,
} from "../db/liveActivityTokens.js";

export const retentionRoute = new Hono<{ Bindings: Env }>();

// Same signing + rate limit as the Live Activity endpoints (register scope).
retentionRoute.use("/retention/*", async (c, next) => {
  const authError = await authenticateSignedRequest(c);
  if (authError) return authError;
  const rateLimitError = await enforceRateLimit(c, "register", 90, 60);
  if (rateLimitError) return rateLimitError;
  await next();
});

// ---------------------------------------------------------------------------
// POST /retention/heartbeat
// The app opened — stamp last_opened_at so the cron knows the user is active.
// ---------------------------------------------------------------------------
retentionRoute.post("/retention/heartbeat", async (c) => {
  const parsed = await parseBody(c, HeartbeatRequestSchema);
  if ("error" in parsed) return parsed.error;

  await markDeviceOpened(c.env.DB, {
    deviceId: parsed.data.deviceId,
    tzOffsetMinutes: parsed.data.tzOffsetMinutes,
  });

  return c.json({ ok: true });
});

// ---------------------------------------------------------------------------
// POST /retention/activity
// The local member added items to a shared list — record it so other members
// can be told "N new items" if they later go inactive.
// ---------------------------------------------------------------------------
retentionRoute.post("/retention/activity", async (c) => {
  const parsed = await parseBody(c, ListActivityRequestSchema);
  if ("error" in parsed) return parsed.error;

  const disabled = await disableHouseholdRegistrationsExceptMembers(
    c.env.DB,
    parsed.data.householdId,
    parsed.data.recipientMemberIds,
  );
  if (disabled > 0) {
    console.log(
      `[retention] disabled stale household registrations ` +
        `household=${parsed.data.householdId} disabledRows=${disabled}`,
    );
  }

  await insertListActivity(c.env.DB, {
    householdId: parsed.data.householdId,
    actorMemberId: parsed.data.actorMemberId,
    actorDisplayName: parsed.data.actorDisplayName,
    itemCount: parsed.data.itemCount,
  });

  return c.json({ ok: true });
});
