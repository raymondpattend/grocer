import Foundation

extension GroceryCategory {
    var localizedName: String {
        switch self {
        case .produce: return String(localized: "Produce")
        case .meatSeafood: return String(localized: "Meat & Seafood")
        case .dairy: return String(localized: "Dairy")
        case .frozen: return String(localized: "Frozen")
        case .pantry: return String(localized: "Pantry")
        case .bakery: return String(localized: "Bakery")
        case .drinks: return String(localized: "Drinks")
        case .snacks: return String(localized: "Snacks")
        case .household: return String(localized: "Household")
        case .personalCare: return String(localized: "Personal Care")
        case .pet: return String(localized: "Pet")
        case .other: return String(localized: "Other")
        }
    }
}

extension ItemPriority {
    var localizedName: String {
        switch self {
        case .low: return String(localized: "Low")
        case .normal: return String(localized: "Normal")
        case .high: return String(localized: "High")
        }
    }
}

extension ItemStatus {
    var localizedName: String {
        switch self {
        case .needed: return String(localized: "Needed")
        case .found: return String(localized: "Found")
        case .replaced: return String(localized: "Replaced")
        case .outOfStock: return String(localized: "Out of Stock")
        case .skipped: return String(localized: "Skipped")
        case .removed: return String(localized: "Removed")
        }
    }
}

extension SessionStatus {
    var localizedName: String {
        switch self {
        case .active: return String(localized: "Active")
        case .completed: return String(localized: "Completed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }
}

extension MemberRole {
    var localizedName: String {
        switch self {
        case .owner: return String(localized: "Owner")
        case .member: return String(localized: "Member")
        }
    }
}

extension ListColorTheme {
    var localizedName: String {
        switch self {
        case .green: return String(localized: "Green")
        case .blue: return String(localized: "Blue")
        case .indigo: return String(localized: "Indigo")
        case .purple: return String(localized: "Purple")
        case .pink: return String(localized: "Pink")
        case .red: return String(localized: "Red")
        case .orange: return String(localized: "Orange")
        case .yellow: return String(localized: "Yellow")
        case .teal: return String(localized: "Teal")
        case .mint: return String(localized: "Mint")
        case .brown: return String(localized: "Brown")
        case .gray: return String(localized: "Gray")
        }
    }
}
