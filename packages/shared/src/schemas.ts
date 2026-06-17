import { z } from "zod";
import {
  GROCERY_CATEGORIES,
  ITEM_STATUSES,
  SESSION_STATUSES,
} from "./constants.js";

/**
 * Zod schemas for the Cloudflare Worker API request/response bodies.
 * The API validates inbound requests against these; the shared package
 * also exports inferred TS types for use elsewhere.
 */

const isoDate = z.string().datetime({ offset: true });

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

export const IOSConfigSchema = z.object({
  minimumSupportedBuild: z.number().int(),
  latestBuild: z.number().int(),
  upgradeRequired: z.boolean(),
  status: z.enum(["ok", "upgrade_required"]),
  updateUrl: z.string().url(),
  features: z.object({
    suggestions: z.boolean(),
    parseList: z.boolean(),
    feedback: z.boolean(),
    liveActivities: z.boolean(),
  }),
});
export type IOSConfig = z.infer<typeof IOSConfigSchema>;

// ---------------------------------------------------------------------------
// Feedback
// ---------------------------------------------------------------------------

export const FeedbackRequestSchema = z.object({
  message: z.string().min(1).max(5000),
  email: z.string().email().optional(),
  appVersion: z.string().max(40).optional(),
  device: z.string().max(120).optional(),
});
export type FeedbackRequest = z.infer<typeof FeedbackRequestSchema>;

// ---------------------------------------------------------------------------
// Suggestions
// ---------------------------------------------------------------------------

export const SuggestionRequestSchema = z.object({
  query: z.string().min(1).max(120),
  recentItems: z.array(z.string().max(120)).max(100).optional(),
  householdContext: z.string().max(500).optional(),
});
export type SuggestionRequest = z.infer<typeof SuggestionRequestSchema>;

export const SuggestionSchema = z.object({
  name: z.string(),
  quantity: z.string().optional(),
  /** Proposed natural unit for this product (e.g. "dozen", "gallon"). */
  unit: z.string().optional(),
  category: z.enum(GROCERY_CATEGORIES),
  notes: z.string().optional(),
});
export type Suggestion = z.infer<typeof SuggestionSchema>;

export const SuggestionResponseSchema = z.object({
  suggestions: z.array(SuggestionSchema),
});
export type SuggestionResponse = z.infer<typeof SuggestionResponseSchema>;

// ---------------------------------------------------------------------------
// Parse list
// ---------------------------------------------------------------------------

export const ParseListRequestSchema = z.object({
  text: z.string().min(1).max(20000),
});
export type ParseListRequest = z.infer<typeof ParseListRequestSchema>;

export const ParsedItemSchema = z.object({
  name: z.string(),
  category: z.enum(GROCERY_CATEGORIES),
  quantity: z.string().optional(),
  /** Proposed natural unit for this product (e.g. "dozen", "gallon"). */
  unit: z.string().optional(),
});
export type ParsedItem = z.infer<typeof ParsedItemSchema>;

export const ParseListResponseSchema = z.object({
  items: z.array(ParsedItemSchema),
});
export type ParseListResponse = z.infer<typeof ParseListResponseSchema>;

// ---------------------------------------------------------------------------
// Live Activity — token registration
// ---------------------------------------------------------------------------

export const RegisterTokenRequestSchema = z.object({
  householdId: z.string().min(1),
  memberId: z.string().min(1),
  deviceId: z.string().min(1),
  pushToStartToken: z.string().min(1).optional(),
  pushNotificationToken: z.string().min(1).optional(),
  familyLiveActivitiesEnabled: z.boolean(),
  notificationsEnabled: z.boolean().optional(),
  appVersion: z.string().max(40).optional(),
  platform: z.literal("iOS").default("iOS"),
  /** Minutes east of UTC (e.g. -480 for PST). Lets the retention cron avoid
   *  sending nudges in the middle of the recipient's night. */
  tzOffsetMinutes: z.number().int().optional(),
});
export type RegisterTokenRequest = z.infer<typeof RegisterTokenRequestSchema>;

/**
 * Authoritative list of the groups this device is *currently* a member of.
 * The backend disables push/notification delivery for any other `device_tokens`
 * row belonging to this device, cleaning up registrations left behind when the
 * user left a group (especially while the app was closed). Idempotent and
 * self-healing: safe to send on every launch.
 */
export const SyncRegistrationsRequestSchema = z.object({
  deviceId: z.string().min(1),
  /** Household ids the device is an active member of. May be empty (no groups). */
  householdIds: z.array(z.string().min(1)).max(500),
});
export type SyncRegistrationsRequest = z.infer<
  typeof SyncRegistrationsRequestSchema
>;

// ---------------------------------------------------------------------------
// Retention — re-engagement nudges
// ---------------------------------------------------------------------------

/** Foreground heartbeat: records that the user opened the app, so the
 *  retention cron can measure how long they've been away. */
export const HeartbeatRequestSchema = z.object({
  householdId: z.string().min(1),
  memberId: z.string().min(1),
  deviceId: z.string().min(1),
  tzOffsetMinutes: z.number().int().optional(),
});
export type HeartbeatRequest = z.infer<typeof HeartbeatRequestSchema>;

/** Reports that the local member added items to a shared list, so the cron can
 *  later tell OTHER members "N new items were added while you were away". */
export const ListActivityRequestSchema = z.object({
  householdId: z.string().min(1),
  actorMemberId: z.string().min(1),
  actorDisplayName: z.string().max(120).optional(),
  deviceId: z.string().min(1),
  itemCount: z.number().int().positive(),
});
export type ListActivityRequest = z.infer<typeof ListActivityRequestSchema>;

/**
 * Per-activity update token. ActivityKit produces a fresh update token for
 * each running Live Activity; the device posts it back so the backend can
 * target that specific activity with update/end pushes.
 */
export const RegisterUpdateTokenRequestSchema = z.object({
  householdId: z.string().min(1),
  memberId: z.string().min(1),
  deviceId: z.string().min(1),
  sessionId: z.string().min(1),
  updateToken: z.string().min(1),
});
export type RegisterUpdateTokenRequest = z.infer<
  typeof RegisterUpdateTokenRequestSchema
>;

// ---------------------------------------------------------------------------
// Live Activity — content state shared with the iOS ActivityAttributes
// ---------------------------------------------------------------------------

/**
 * Mirror of the Swift `GroceryActivityAttributes.ContentState`.
 * The APNs ActivityKit payload's `content-state` is built from this shape.
 */
export const LiveActivityContentSchema = z.object({
  storeName: z.string().nullable().optional(),
  shopperName: z.string(),
  status: z.enum(SESSION_STATUSES),
  itemsFound: z.number().int().nonnegative(),
  itemsRemaining: z.number().int().nonnegative(),
  totalItems: z.number().int().nonnegative(),
  outOfStockCount: z.number().int().nonnegative(),
  replacedCount: z.number().int().nonnegative(),
  lastHandledItemName: z.string().nullable().optional(),
  lastHandledItemStatus: z.enum(ITEM_STATUSES).nullable().optional(),
});
export type LiveActivityContent = z.infer<typeof LiveActivityContentSchema>;

export const StartLiveActivityRequestSchema = LiveActivityContentSchema.extend({
  householdId: z.string().min(1),
  sessionId: z.string().min(1),
  // Forwarded into the Live Activity attributes so the widget can look up the
  // shopper's avatar (keyed by member id). Optional for older clients.
  startedByMemberId: z.string().min(1).optional(),
  sourceDeviceId: z.string().min(1).optional(),
  startedAt: isoDate,
});
export type StartLiveActivityRequest = z.infer<
  typeof StartLiveActivityRequestSchema
>;

export const UpdateLiveActivityRequestSchema = LiveActivityContentSchema.extend(
  {
    householdId: z.string().min(1),
    sessionId: z.string().min(1),
    updatedAt: isoDate,
  },
);
export type UpdateLiveActivityRequest = z.infer<
  typeof UpdateLiveActivityRequestSchema
>;

export const EndLiveActivityRequestSchema = z.object({
  householdId: z.string().min(1),
  sessionId: z.string().min(1),
  sourceDeviceId: z.string().min(1).optional(),
  storeName: z.string().nullable().optional(),
  shopperName: z.string().optional(),
  status: z.enum(["completed", "cancelled"]),
  itemsFound: z.number().int().nonnegative(),
  itemsRemaining: z.number().int().nonnegative(),
  totalItems: z.number().int().nonnegative(),
  outOfStockCount: z.number().int().nonnegative(),
  replacedCount: z.number().int().nonnegative(),
  endedAt: isoDate,
});
export type EndLiveActivityRequest = z.infer<
  typeof EndLiveActivityRequestSchema
>;

/**
 * "Heads up, I'm about to shop" ping. Fans out a Time Sensitive notification to
 * every other member of the group — no shopping session is involved yet.
 */
export const HeadsUpRequestSchema = z.object({
  householdId: z.string().min(1),
  sourceDeviceId: z.string().min(1).optional(),
  shopperName: z.string().min(1),
  storeName: z.string().nullable().optional(),
  sentAt: isoDate,
});
export type HeadsUpRequest = z.infer<typeof HeadsUpRequestSchema>;

export const PushFanoutResponseSchema = z.object({
  ok: z.boolean(),
  sent: z.number().int().nonnegative(),
  failed: z.number().int().nonnegative(),
  notificationsSent: z.number().int().nonnegative().optional(),
  notificationsFailed: z.number().int().nonnegative().optional(),
});
export type PushFanoutResponse = z.infer<typeof PushFanoutResponseSchema>;

export const OkResponseSchema = z.object({ ok: z.boolean() });
export type OkResponse = z.infer<typeof OkResponseSchema>;
