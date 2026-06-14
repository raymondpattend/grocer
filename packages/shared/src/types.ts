import type {
  GroceryCategory,
  GroupColorTheme,
  ItemStatus,
  MemberRole,
  SessionStatus,
} from "./constants.js";

/**
 * Domain model types shared as documentation between the iOS app (Swift)
 * and the API. CloudKit is the source of truth for these records; the API
 * only persists the Live-Activity subset (see db/schema.ts).
 */

/** A group is also the grocery list: it carries the store, icon, and theme. */
export interface Household {
  id: string;
  name: string;
  ownerMemberId: string;
  storeName?: string;
  icon: string;
  colorTheme: GroupColorTheme;
  createdAt: string;
  updatedAt: string;
}

export interface HouseholdMember {
  id: string;
  householdId: string;
  displayName: string;
  /** CloudKit CKAsset field on the shared HouseholdMember record. */
  profileImage?: string;
  iCloudUserRecordName?: string;
  role: MemberRole;
  joinedAt: string;
}

/** Internal 1:1 container for a group's items (not surfaced in the UI). */
export interface GroceryList {
  id: string;
  householdId: string;
  name: string;
  createdAt: string;
  updatedAt: string;
  archived: boolean;
}

export interface GroceryItem {
  id: string;
  householdId: string;
  listId: string;
  name: string;
  quantity?: string;
  category: GroceryCategory;
  notes?: string;
  requestedByMemberId: string;
  requestedByDisplayName: string;
  status: ItemStatus;
  replacementPreference?: string;
  replacementItemName?: string;
  createdAt: string;
  updatedAt: string;
  completedAt?: string;
  activeSessionId?: string;
}

export interface ShoppingSession {
  id: string;
  householdId: string;
  listId: string;
  startedByMemberId: string;
  startedByDisplayName: string;
  storeName?: string;
  startedAt: string;
  endedAt?: string;
  updatedAt: string;
  status: SessionStatus;
}

export type ItemEventType =
  | "itemAdded"
  | "itemEdited"
  | "itemFound"
  | "itemReplaced"
  | "itemOutOfStock"
  | "itemSkipped"
  | "itemRemoved"
  | "sessionStarted"
  | "sessionCompleted"
  | "sessionCancelled";

export interface ItemEvent {
  id: string;
  householdId: string;
  itemId?: string;
  sessionId?: string;
  type: ItemEventType;
  createdByMemberId: string;
  createdByDisplayName: string;
  createdAt: string;
  metadata?: Record<string, string>;
}
