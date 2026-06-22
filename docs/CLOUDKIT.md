# CloudKit Setup

CloudKit is the source of truth for all grocery data. This guide covers the
container, databases, record types, indexes, and the family Sharing flow.

## 1. Container

Create an iCloud container in the Apple Developer portal (or let Xcode create it
from the iCloud capability), e.g. **`iCloud.com.example.grocer`**.

Update the identifier in three places if you change it:

- `apps/ios/Grocer/Grocer.entitlements` → `com.apple.developer.icloud-container-identifiers`
- `apps/ios/Grocer/Models/CloudKitSchema.swift` → `CK.containerIdentifier`
- (project.yml bundle ids if you also rename the app)

## 2. Databases & zone

| Database    | Used for                                                            |
| ----------- | ------------------------------------------------------------------- |
| **Private** | The owner's copy of all household data, in a custom zone (see below). Also personal settings / recent items. |
| **Shared**  | Where family members (participants) see the shared household zone after accepting the invite. |

All shared household records live in a **custom record zone** named
`HouseholdZone` in the owner's **private** database. The `Household` record is
the **share root** (`CKShare` is rooted there) so the entire zone is shared as a
unit. The app reads from the private DB (if you're the owner) and the shared DB
(if you're a participant). The zone is created automatically on first launch
(`CloudKitService.ensureZone()`).

## 3. Record types & fields

CloudKit in the **development** environment auto-creates record types and fields
the first time the app saves a record. The schema below documents what the app
writes (field keys come from `CloudKitSchema.swift`). Promote the schema to
**production** from the CloudKit Console before shipping.

### When "Deploy Schema Changes" shows nothing

Deploy only copies fields that exist in **Development** but not **Production**.
If a field was added to the app after `ShoppingTripItem` records were already
saved in Development *without* that field, Development and Production can both
be missing it — and there is nothing to deploy.

Add the field manually in the CloudKit Console:

1. Open [CloudKit Console](https://icloud.developer.apple.com/) → your container.
2. Switch the environment to **Production** (top-left).
3. **Schema** → **Record Types** → `ShoppingTripItem`.
4. **Add Field** → name `replacementItemName`, type **String**, not queryable.
5. Save, then repeat in **Development** if that environment is also missing the field.

After the field exists, trip snapshots can store replacement names again. Until
then, the app omits that field on `ShoppingTripItem` saves so trip completion
still syncs.

### Household
A group *is* the grocery list — it carries the store, icon, and color theme.
| Field | Type |
| --- | --- |
| `name` | String |
| `ownerMemberId` | String |
| `storeName` | String |
| `storeLatitude` | Double (optional; linked-store geofence) |
| `storeLongitude` | Double (optional; linked-store geofence) |
| `storeRadius` | Double (optional; meters, geofence radius) |
| `icon` | String (SF Symbol name) |
| `colorTheme` | String (e.g. `green`, `blue`, `teal`) |
| `createdAt` | Date/Time |
| `updatedAt` | Date/Time |

### HouseholdMember
| Field | Type |
| --- | --- |
| `householdId` | String (Queryable) |
| `displayName` | String |
| `profileImage` | Asset |
| `iCloudUserRecordName` | String |
| `role` | String |
| `joinedAt` | Date/Time |

### GroceryList
| Field | Type |
| --- | --- |
| `householdId` | String (Queryable) |
| `name` | String |
| `archived` | Int64 (0/1) |
| `createdAt` / `updatedAt` | Date/Time |

### GroceryItem
| Field | Type |
| --- | --- |
| `householdId` | String (Queryable) |
| `listId` | String (Queryable) |
| `name` | String |
| `quantity` | String |
| `category` | String |
| `notes` | String |
| `priority` | String |
| `requestedByMemberId` | String |
| `requestedByDisplayName` | String |
| `status` | String (Queryable) |
| `replacementPreference` | String |
| `replacementItemName` | String |
| `createdAt` / `updatedAt` / `completedAt` / `deletedAt` | Date/Time |
| `activeSessionId` | String (Queryable) |
| `photo` | Asset (optional user-taken item photo, shared with the group) |

> **`photo` schema deploy:** like `ShoppingTripItem.replacementItemName`, the
> `photo` field auto-creates in **Development** on first write but must be added
> to **Production** before release (Console → `GroceryItem` → **Add Field** →
> `photo`, type **Asset**, not queryable). Until it exists, the app omits the
> photo on item saves so the rest of the item still syncs (see
> `supportsItemPhotoField` in `GroceryRepository`).

### ShoppingSession
| Field | Type |
| --- | --- |
| `householdId` | String (Queryable) |
| `listId` | String (Queryable) |
| `startedByMemberId` | String |
| `startedByDisplayName` | String |
| `storeName` | String |
| `startedAt` / `endedAt` / `updatedAt` | Date/Time |
| `status` | String (Queryable) |

### ShoppingTripItem
An immutable per-item snapshot of one finished trip, written when the trip ends
(the live `GroceryItem` is reused across trips, so its `activeSessionId` link
can't serve as history). Record name is `"<sessionId>_<itemId>"`. `status`
holds the outcome (`Found`/`Replaced`/`Out of Stock`/`Skipped`/`Removed`, or
`Needed` for items left unfound).
| Field | Type |
| --- | --- |
| `householdId` | String (Queryable) |
| `sessionId` | String (Queryable) |
| `itemId` | String |
| `name` | String |
| `quantity` | String |
| `category` | String |
| `status` | String (outcome) |
| `replacementItemName` | String |
| `requestedByMemberId` | String |
| `requestedByDisplayName` | String |
| `createdAt` | Date/Time (capture time == trip end) |

### ItemEvent
| Field | Type |
| --- | --- |
| `householdId` | String (Queryable) |
| `itemId` | String (Queryable) |
| `sessionId` | String (Queryable) |
| `eventType` | String |
| `createdByMemberId` | String |
| `createdByDisplayName` | String |
| `createdAt` | Date/Time |
| `metadata` | Bytes (JSON-encoded `[String:String]`) |

## 4. Recommended indexes

In the CloudKit Console, add **Queryable** indexes for the fields marked above
(at minimum `householdId`, `listId`, `status`, `activeSessionId`, `sessionId`,
`itemId`) and the system **recordName** index per record type. For
`ShoppingTripItem`, index `householdId` and `sessionId`. The app queries by zone
+ record type, so per-type recordName queryability is required.

## 5. Family Sharing flow

1. Owner creates the household (automatic on first launch).
2. Owner opens **Settings → Invite Family Member**.
3. The app presents `UICloudSharingController` (`CloudSharingView`) with a
   `CKShare` rooted at the `Household` record.
4. The family member taps the invite link; iOS hands the
   `CKShare.Metadata` to `AppDelegate.application(_:userDidAcceptCloudKitShareWith:)`,
   which routes it to `GroceryRepository.acceptShare(_:)` →
   `container.accept(_:)`.
5. The shared `HouseholdZone` now appears in the participant's **shared**
   database, and the family grocery list shows up in their app.

## 6. Notes & limitations

- Requires a signed-in iCloud account on device. Without one, the app runs on
  local sample data (no sync, no sharing).
- Participant writes are routed to the shared zone's database. Conflict handling
  is latest-write-wins on mutable fields, while item events are preserved for
  audit/history.
- The app persists a local CloudKit snapshot plus a durable pending-write outbox
  in Application Support. Changes made while CloudKit is unavailable are applied
  optimistically, survive relaunch, and flush when connectivity/account access
  returns.
- The app stores per-zone server change tokens and fetches incremental changes
  after the initial snapshot. If CloudKit expires a token, the app falls back to a
  full zone refetch and clears records for that zone before applying the fresh
  contents.
- Grocery item removal is a soft delete (`status = removed`, `deletedAt` set) so
  concurrent add/remove/edit races converge through normal record updates instead
  of disappearing until a forced refresh.
- The app registers a private record-zone subscription for groups the current
  user owns and a shared-database subscription for groups the user joined. A
  silent push wakes the app, then the repository refreshes its CloudKit changes.
  iOS may delay silent pushes, so launch, foreground activation, and
  pull-to-refresh also fetch changes.
