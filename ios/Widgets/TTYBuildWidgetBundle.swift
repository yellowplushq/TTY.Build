import SwiftUI
import WidgetKit

@main
struct TTYBuildWidgetBundle: WidgetBundle {
    var body: some Widget {
        TTYCountWidget()
        TTYLiveActivityWidget()
    }
}
