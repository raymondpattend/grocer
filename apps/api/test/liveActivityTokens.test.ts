import { describe, expect, it } from "vitest";

import { disableStaleDeviceRegistrations } from "../src/db/liveActivityTokens.js";

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
