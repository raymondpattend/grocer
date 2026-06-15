import { describe, expect, it } from "vitest";
import { configRoute } from "../src/routes/config.js";

const env = {
  IOS_MIN_BUILD: "12",
  IOS_LATEST_BUILD: "15",
  IOS_UPDATE_URL: "https://example.com/grocer",
};

async function iosConfig(path: string) {
  const response = await configRoute.request(path, {}, env);
  return response.json();
}

describe("ios config", () => {
  it("requires an upgrade when the current build is below the minimum", async () => {
    await expect(iosConfig("/config/ios?build=11")).resolves.toMatchObject({
      minimumSupportedBuild: 12,
      latestBuild: 15,
      upgradeRequired: true,
      status: "upgrade_required",
      updateUrl: "https://example.com/grocer",
    });
  });

  it("allows current builds at or above the minimum", async () => {
    await expect(iosConfig("/config/ios?build=12")).resolves.toMatchObject({
      upgradeRequired: false,
      status: "ok",
    });
  });

  it("keeps legacy config requests non-blocking when no build is provided", async () => {
    await expect(iosConfig("/config/ios")).resolves.toMatchObject({
      upgradeRequired: false,
      status: "ok",
    });
  });

  it("includes external purchase storefronts for iOS payment gating", async () => {
    await expect(iosConfig("/config/ios")).resolves.toMatchObject({
      payments: {
        externalPurchaseStorefronts: ["USA"],
      },
    });
  });
});
