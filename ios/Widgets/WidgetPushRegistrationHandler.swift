import Foundation
import WidgetKit

struct IOSWidgetPushHandler: WidgetPushHandler {
    init() {}

    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        // Persist before returning from the extension callback; the process
        // may be suspended before an asynchronous network task starts.
        StatusSharedStore.saveWidgetPushObservation(
            .init(surface: .iOSWidget, token: pushInfo.token.ttybuildHexString),
            hasConfiguredWidgets: !widgets.isEmpty
        )
        PushEndpointRegistrar.requestFlush()
    }
}
