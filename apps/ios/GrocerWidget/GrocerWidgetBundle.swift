import SwiftUI
import WidgetKit

@main
struct GrocerWidgetBundle: WidgetBundle {
    var body: some Widget {
        GroceryListWidget()
        GroceryLiveActivity()
    }
}
