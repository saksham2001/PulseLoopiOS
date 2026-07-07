import WidgetKit
import SwiftUI

@main
struct PulseLoopWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PulseLoopActivityWidget()
        PulseLoopMetricWidget()
        PulseLoopDualMetricWidget()
    }
}
