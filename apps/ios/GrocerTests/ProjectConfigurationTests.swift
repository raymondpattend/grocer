import XCTest

final class ProjectConfigurationTests: XCTestCase {
    func testPostHogSkipsSetupInsteadOfCrashingWhenTokenMissing() throws {
        let app = try source("Grocer/GrocerApp.swift")

        XCTAssertTrue(app.contains("configureIfAvailable()"))
        XCTAssertFalse(app.contains("fatalError"), "PostHog must not trap when the token is missing in TestFlight builds")
    }

    func testCloudKitEntitlementsAndBackgroundRefreshModesArePresent() throws {
        let entitlements = try source("Grocer/Grocer.entitlements")
        let infoPlist = try source("Grocer/Info.plist")
        let widgetEntitlements = try source("GrocerWidget/GrocerWidget.entitlements")

        XCTAssertTrue(entitlements.contains("iCloud.org.narro.grocer"))
        XCTAssertTrue(entitlements.contains("<string>CloudKit</string>"))
        XCTAssertTrue(entitlements.contains("aps-environment"))
        XCTAssertTrue(entitlements.contains("$(APS_ENVIRONMENT)"))
        XCTAssertTrue(entitlements.contains("group.org.narro.grocer"))
        XCTAssertTrue(widgetEntitlements.contains("group.org.narro.grocer"))
        // Universal Links for share.grocer.sh invite links.
        XCTAssertTrue(entitlements.contains("com.apple.developer.associated-domains"))
        XCTAssertTrue(entitlements.contains("applinks:share.grocer.sh"))
        XCTAssertTrue(infoPlist.contains("<string>remote-notification</string>"))
        XCTAssertTrue(infoPlist.contains("<key>CKSharingSupported</key>"))
        XCTAssertTrue(infoPlist.contains("<key>GRLiveActivityAPISecret</key>"))
        XCTAssertTrue(infoPlist.contains("<key>GRPostHogProjectToken</key>"))
        XCTAssertTrue(infoPlist.contains("<key>GRPostHogHost</key>"))
    }

    func testCloudKitEnvironmentScopingProtectsDevelopmentAndProductionCaches() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let cloud = try source("Grocer/Services/CloudKitService.swift")
        let sharedData = try source("Grocer/Shared/WidgetSharedData.swift")

        XCTAssertTrue(repo.contains("CloudKitEnvironment.current"))
        XCTAssertTrue(repo.contains("root.appendingPathComponent(CloudKitEnvironment.current"))
        XCTAssertTrue(cloud.contains("[Self.changeTokenKeyPrefix, CloudKitEnvironment.current"))
        XCTAssertTrue(cloud.contains("[\"grocer.cloudkit.knownSharedZones\", CloudKitEnvironment.current]"))
        // The subscription-registered flags must be environment-scoped too, or a
        // dev-profiled Release build can suppress the prod build's registration.
        XCTAssertTrue(cloud.contains("[\"grocer.cloudkit.subscriptionsRegistered\", CloudKitEnvironment.current]"))
        XCTAssertTrue(cloud.contains("[\"grocer.cloudkit.subscriptionsRegisteredVersion\", CloudKitEnvironment.current]"))
        XCTAssertTrue(sharedData.contains("environmentSuffix"))
    }

    func testCloudKitSchemaConstantsMatchEntitledContainer() throws {
        let schema = try source("Grocer/Models/CloudKitSchema.swift")
        let entitlements = try source("Grocer/Grocer.entitlements")

        XCTAssertTrue(schema.contains("static let containerIdentifier = \"iCloud.org.narro.grocer\""))
        XCTAssertTrue(entitlements.contains("<string>iCloud.org.narro.grocer</string>"))
        XCTAssertTrue(schema.contains("static let householdZoneName = \"HouseholdZone\""))
    }

    func testCloudKitDocsCoverRequiredIndexesAndSharingShape() throws {
        let docs = try source("../../docs/CLOUDKIT.md")

        XCTAssertTrue(docs.contains("custom record zone"))
        XCTAssertTrue(docs.contains("The `Household` record is"))
        XCTAssertTrue(docs.contains("private DB"))
        XCTAssertTrue(docs.contains("shared DB"))
        XCTAssertTrue(docs.contains("Queryable"))
        XCTAssertTrue(docs.contains("recordName"))
        XCTAssertTrue(docs.contains("change tokens"))
    }

    func testCloudKitDocsIncludePriorityField() throws {
        let docs = try source("../../docs/CLOUDKIT.md")
        let groceryItemSection = try excerpt(docs, from: "### GroceryItem", to: "### ShoppingSession")

        XCTAssertTrue(groceryItemSection.contains("`priority`"))
    }

    func testLiveActivityWorkerEndpointsAuthenticateCallers() throws {
        let apiClient = try source("Grocer/Services/APIClient.swift")
        let route = try source("../api/src/routes/liveActivity.ts")
        let project = try source("project.yml")
        let secretExample = try source("Config/Secrets.xcconfig.example")

        XCTAssertTrue(apiClient.contains("HMAC<SHA256>"))
        XCTAssertTrue(apiClient.contains("x-grocer-signature"))
        XCTAssertTrue(route.contains("authenticateLiveActivityRequest"))
        XCTAssertTrue(route.contains("x-grocer-signature"))
        XCTAssertTrue(route.contains("consumeRateLimit"))
        XCTAssertTrue(secretExample.contains("LIVE_ACTIVITY_API_SECRET ="))
        XCTAssertFalse(
            project.contains("LIVE_ACTIVITY_API_SECRET: \"\""),
            "An empty project-level LIVE_ACTIVITY_API_SECRET overrides Config/Secrets.xcconfig and disables Live Activity/APNs calls."
        )
    }
}
