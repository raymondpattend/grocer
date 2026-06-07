import Foundation

/// On-device category guesser so the app works fully without the web API.
/// The API's /suggestions and /parse-list provide richer results when online;
/// this is the always-available fallback.
enum CategoryGuess {
    private static let keywords: [(GroceryCategory, [String])] = [
        (.produce, ["banana", "apple", "lettuce", "spinach", "tomato", "berry", "strawberr", "blueberr", "avocado", "onion", "potato", "carrot", "pepper", "fruit", "veg", "lime", "lemon", "grape", "celery", "broccoli", "cucumber"]),
        (.meatSeafood, ["chicken", "beef", "pork", "turkey", "salmon", "bacon", "shrimp", "steak", "sausage", "fish", "tuna", "meat"]),
        (.dairy, ["milk", "egg", "butter", "cheese", "yogurt", "cream", "cottage"]),
        (.frozen, ["frozen", "ice cream", "popsicle", "pizza"]),
        (.bakery, ["bread", "bagel", "tortilla", "roll", "bun", "muffin", "croissant", "cake", "donut"]),
        (.drinks, ["coffee", "juice", "water", "soda", "tea", "drink", "seltzer", "beer", "wine", "lemonade"]),
        (.snacks, ["chip", "cracker", "cookie", "granola", "candy", "chocolate", "popcorn", "pretzel", "nuts", "snack"]),
        (.household, ["paper towel", "toilet", "dish soap", "detergent", "trash", "foil", "wrap", "sponge", "battery", "cleaner", "bleach"]),
        (.personalCare, ["shampoo", "toothpaste", "deodorant", "soap", "lotion", "razor", "floss", "mouthwash", "sunscreen", "vitamin"]),
        (.pet, ["dog", "cat", "pet", "litter"]),
        (.pantry, ["rice", "pasta", "cereal", "peanut butter", "olive oil", "flour", "sugar", "sauce", "soup", "bean", "spice", "oil", "vinegar", "honey", "syrup", "oats", "canned"]),
    ]

    static func guess(for name: String) -> GroceryCategory {
        let n = name.lowercased()
        for (category, terms) in keywords where terms.contains(where: { n.contains($0) }) {
            return category
        }
        return .other
    }
}
