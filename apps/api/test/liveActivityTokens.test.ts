import { describe, expect, it } from "vitest";

import {
  activityTokensForSession,
  disableHouseholdRegistrationsExceptMembers,
  disableStaleDeviceRegistrations,
  eligibleNotificationTokens,
  eligibleStartTokens,
  invalidateSessionActivityTokensExceptMembers,
} from "../src/db/liveActivityTokens.js";

/** Minimal D1 fake that records the SQL + bound args of the last statement. */
function fakeDB(changes = 0) {
  const calls: { sql: string; args: unknown[] }[] = [];
  const db = {
    calls,
    prepare(sql: string) {
      const stmt = {
        bind(...args: unknown[]) {
          calls.push({ sql, args });
          return {
            run: async () => ({ meta: { changes } }),
            all: async <T>() => ({ results: [] as T[] }),
          };
        },
      };
      return stmt;
    },
  };
  return db as unknown as D1Database & { calls: typeof calls };
}

describe("disableStaleDeviceRegistrations", () => {
  it("scopes the disable to the device and excludes the active households", async () => {
    const db = fakeDB(2);
    const n = await disableStaleDeviceRegistrations(db, "dev-1", ["hh-a", "hh-b"]);

    expect(n).toBe(2);
    const { sql, args } = (db as never as { calls: { sql: string; args: unknown[] }[] }).calls[0];
    expect(sql).toContain("device_id = ?");
    expect(sql).toContain("household_id NOT IN (?, ?)");
    // Disables every delivery flag, never re-enables.
    expect(sql).toContain("notifications_enabled = 0");
    expect(sql).toContain("live_activities_enabled = 0");
    expect(sql).toContain("token_valid = 0");
    expect(sql).toContain("notification_token_valid = 0");
    // Bind order: updated_at, deviceId, ...householdIds
    expect(args.slice(1)).toEqual(["dev-1", "hh-a", "hh-b"]);
  });

  it("de-dupes household ids so the placeholder count matches the binds", async () => {
    const db = fakeDB(0);
    await disableStaleDeviceRegistrations(db, "dev-1", ["hh-a", "hh-a", "hh-b"]);

    const { sql, args } = (db as never as { calls: { sql: string; args: unknown[] }[] }).calls[0];
    expect(sql).toContain("household_id NOT IN (?, ?)");
    expect(args.slice(1)).toEqual(["dev-1", "hh-a", "hh-b"]);
  });

  it("disables ALL of the device's rows when it belongs to no groups", async () => {
    const db = fakeDB(3);
    const n = await disableStaleDeviceRegistrations(db, "dev-1", []);

    expect(n).toBe(3);
    const { sql, args } = (db as never as { calls: { sql: string; args: unknown[] }[] }).calls[0];
    expect(sql).toContain("WHERE device_id = ?");
    expect(sql).not.toContain("NOT IN");
    expect(args.slice(1)).toEqual(["dev-1"]);
  });
});

describe("fanout recipient filters", () => {
  it("limits push-to-start fanout to the explicit member roster", async () => {
    const db = fakeDB();
    await eligibleStartTokens(db, "hh-1", "source-device", ["member-a", "member-a", "member-b"]);

    const { sql, args } = (db as never as { calls: { sql: string; args: unknown[] }[] }).calls[0];
    expect(sql).toContain("household_id = ?1");
    expect(sql).toContain("device_id <> ?2");
    expect(sql).toContain("member_id IN (?3, ?4)");
    expect(args).toEqual(["hh-1", "source-device", "member-a", "member-b"]);
  });

  it("limits notification fanout to the explicit member roster", async () => {
    const db = fakeDB();
    await eligibleNotificationTokens(db, "hh-1", undefined, ["member-a"]);

    const { sql, args } = (db as never as { calls: { sql: string; args: unknown[] }[] }).calls[0];
    expect(sql).toContain("household_id = ?1");
    expect(sql).toContain("member_id IN (?2)");
    expect(args).toEqual(["hh-1", "member-a"]);
  });

  it("returns no device-token candidates for an explicitly empty roster", async () => {
    const db = fakeDB();
    await eligibleStartTokens(db, "hh-1", undefined, []);

    const { sql, args } = (db as never as { calls: { sql: string; args: unknown[] }[] }).calls[0];
    expect(sql).toContain("AND 0");
    expect(sql).not.toContain("member_id IN");
    expect(args).toEqual(["hh-1"]);
  });

  it("limits activity update tokens to the session household and roster", async () => {
    const db = fakeDB();
    await activityTokensForSession(db, "session-1", "hh-1", ["member-a", "member-b"]);

    const { sql, args } = (db as never as { calls: { sql: string; args: unknown[] }[] }).calls[0];
    expect(sql).toContain("session_id = ?1");
    expect(sql).toContain("household_id = ?2");
    expect(sql).toContain("member_id IN (?3, ?4)");
    expect(args).toEqual(["session-1", "hh-1", "member-a", "member-b"]);
  });
});

describe("household recipient cleanup", () => {
  it("disables household delivery rows for members outside the roster", async () => {
    const db = fakeDB(2);
    const n = await disableHouseholdRegistrationsExceptMembers(db, "hh-1", [
      "member-a",
      "member-a",
      "member-b",
    ]);

    expect(n).toBe(2);
    const { sql, args } = (db as never as { calls: { sql: string; args: unknown[] }[] }).calls[0];
    expect(sql).toContain("WHERE household_id = ? AND member_id NOT IN (?, ?)");
    expect(sql).toContain("notifications_enabled = 0");
    expect(sql).toContain("live_activities_enabled = 0");
    expect(sql).toContain("token_valid = 0");
    expect(sql).toContain("notification_token_valid = 0");
    expect(args.slice(1)).toEqual(["hh-1", "member-a", "member-b"]);
  });

  it("skips household cleanup when no authoritative roster is supplied", async () => {
    const db = fakeDB(2);
    const n = await disableHouseholdRegistrationsExceptMembers(db, "hh-1", undefined);

    expect(n).toBe(0);
    expect((db as never as { calls: unknown[] }).calls).toEqual([]);
  });

  it("disables every household delivery row for an explicit empty roster", async () => {
    const db = fakeDB(3);
    const n = await disableHouseholdRegistrationsExceptMembers(db, "hh-1", []);

    expect(n).toBe(3);
    const { sql, args } = (db as never as { calls: { sql: string; args: unknown[] }[] }).calls[0];
    expect(sql).toContain("WHERE household_id = ?");
    expect(sql).not.toContain("NOT IN");
    expect(args.slice(1)).toEqual(["hh-1"]);
  });

  it("invalidates session activity tokens outside the roster", async () => {
    const db = fakeDB(1);
    const n = await invalidateSessionActivityTokensExceptMembers(db, {
      sessionId: "session-1",
      householdId: "hh-1",
      activeMemberIds: ["member-a", "member-b"],
    });

    expect(n).toBe(1);
    const { sql, args } = (db as never as { calls: { sql: string; args: unknown[] }[] }).calls[0];
    expect(sql).toContain("WHERE session_id = ? AND household_id = ? AND member_id NOT IN (?, ?)");
    expect(sql).toContain("token_valid = 0");
    expect(args.slice(1)).toEqual(["session-1", "hh-1", "member-a", "member-b"]);
  });
});
