import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// --- Mocks for the side-effecting collaborators ----------------------------
const sendRetentionNotification = vi.fn();
const retentionCandidates = vi.fn();
const unseenActivityForMember = vi.fn();
const markRetentionPushSent = vi.fn();
const invalidateNotificationToken = vi.fn();
const logApns = vi.fn();
const capture = vi.fn();
const getFeatureFlag = vi.fn();
const getFeatureFlagPayload = vi.fn();

vi.mock("../src/services/apns.js", () => ({
  sendRetentionNotification: (...args: unknown[]) =>
    sendRetentionNotification(...args),
}));

vi.mock("../src/db/liveActivityTokens.js", () => ({
  retentionCandidates: (...a: unknown[]) => retentionCandidates(...a),
  unseenActivityForMember: (...a: unknown[]) => unseenActivityForMember(...a),
  markRetentionPushSent: (...a: unknown[]) => markRetentionPushSent(...a),
  invalidateNotificationToken: (...a: unknown[]) => invalidateNotificationToken(...a),
  logApns: (...a: unknown[]) => logApns(...a),
}));

vi.mock("../src/lib/posthog.js", () => ({
  createPostHogClient: () => ({
    getFeatureFlag,
    getFeatureFlagPayload,
    capture,
    shutdown: vi.fn().mockResolvedValue(undefined),
  }),
}));

import { runRetentionSweep } from "../src/cron/retention.js";

const env = { DB: {}, POSTHOG_API_KEY: "x", POSTHOG_HOST: "y" } as never;

// 2025-06-16T18:00:00Z — afternoon at UTC+0.
const NOW = new Date("2025-06-16T18:00:00Z").getTime();
const daysAgo = (n: number) => new Date(NOW - n * 86_400_000).toISOString();

function candidate(overrides: Record<string, unknown> = {}) {
  return {
    device_id: "dev-1",
    household_id: "hh-1",
    member_id: "mem-1",
    push_to_start_token: null,
    push_notification_token: "tok-1",
    live_activities_enabled: 1,
    notifications_enabled: 1,
    token_valid: 1,
    notification_token_valid: 1,
    last_opened_at: daysAgo(10),
    last_retention_push_at: null,
    tz_offset_minutes: 0, // local hour == UTC hour == 18 → daytime
    app_version: "1",
    platform: "iOS",
    created_at: daysAgo(30),
    updated_at: daysAgo(10),
    ...overrides,
  };
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(NOW);
  sendRetentionNotification.mockResolvedValue({ ok: true, statusCode: 200, apnsId: "a", tokenExpired: false });
  unseenActivityForMember.mockResolvedValue({ itemCount: 3, entries: 1, lastActorName: "Sarah" });
  getFeatureFlag.mockResolvedValue(undefined);
  getFeatureFlagPayload.mockResolvedValue(null);
});

afterEach(() => {
  vi.clearAllMocks();
  vi.useRealTimers();
});

describe("runRetentionSweep", () => {
  it("nudges an inactive user when others added items", async () => {
    retentionCandidates.mockResolvedValue([candidate()]);
    const r = await runRetentionSweep(env);
    expect(r.sent).toBe(1);
    expect(sendRetentionNotification).toHaveBeenCalledWith(
      env,
      "tok-1",
      expect.objectContaining({ householdId: "hh-1", newItemCount: 3, actorName: "Sarah" }),
    );
    expect(markRetentionPushSent).toHaveBeenCalledOnce();
    expect(capture).toHaveBeenCalledWith(
      expect.objectContaining({ event: "retention_notification_sent" }),
    );
  });

  it("skips a user who opened the app recently", async () => {
    retentionCandidates.mockResolvedValue([candidate({ last_opened_at: daysAgo(1) })]);
    const r = await runRetentionSweep(env);
    expect(r.sent).toBe(0);
    expect(r.skipped).toBe(1);
    expect(sendRetentionNotification).not.toHaveBeenCalled();
  });

  it("skips when it is night-time for the recipient", async () => {
    // 18:00Z + 8h = 02:00 local → outside 9am–8pm.
    retentionCandidates.mockResolvedValue([candidate({ tz_offset_minutes: 480 })]);
    const r = await runRetentionSweep(env);
    expect(r.sent).toBe(0);
    expect(sendRetentionNotification).not.toHaveBeenCalled();
  });

  it("skips when no other member added anything", async () => {
    retentionCandidates.mockResolvedValue([candidate()]);
    unseenActivityForMember.mockResolvedValue({ itemCount: 0, entries: 0, lastActorName: null });
    const r = await runRetentionSweep(env);
    expect(r.sent).toBe(0);
    expect(sendRetentionNotification).not.toHaveBeenCalled();
  });

  it("respects the 7-day frequency cap", async () => {
    retentionCandidates.mockResolvedValue([
      candidate({ last_retention_push_at: daysAgo(2) }),
    ]);
    const r = await runRetentionSweep(env);
    expect(r.sent).toBe(0);
    expect(r.skipped).toBe(1);
  });

  it("honors an A/B variant that widens the inactivity window", async () => {
    // Variant "7" days; user inactive only 5 days → not yet eligible.
    getFeatureFlag.mockResolvedValue("7");
    retentionCandidates.mockResolvedValue([candidate({ last_opened_at: daysAgo(5) })]);
    const r = await runRetentionSweep(env);
    expect(r.sent).toBe(0);
    expect(r.skipped).toBe(1);
  });

  it("invalidates a dead token instead of sending", async () => {
    retentionCandidates.mockResolvedValue([candidate()]);
    sendRetentionNotification.mockResolvedValue({
      ok: false,
      statusCode: 410,
      tokenExpired: true,
      reason: "Unregistered",
    });
    const r = await runRetentionSweep(env);
    expect(r.sent).toBe(0);
    expect(r.failed).toBe(1);
    expect(invalidateNotificationToken).toHaveBeenCalledWith(env.DB, "tok-1");
  });
});
