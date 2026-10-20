import AppKit

/// A pen's pressure as it paints. A drawing tablet's pen, and Apple Pencil on
/// an iPad used as a Sidecar display, reach the app as mouse events with
/// tablet readings attached (and tablet events between them); a mouse or
/// trackpad has none, and paints at full strength.
@MainActor final class PenInput {
    static let shared = PenInput()

    /// the latest reading, 0...1, while a pen is down; nil for a mouse or trackpad
    private(set) var pressure: Double?
    /// the pen's eraser end is towards the screen (a tablet pen's; Apple Pencil has none)
    private(set) var eraser = false
    private var monitor: Any?

    /// Starts reading, while painting is possible.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .tabletPoint, .tabletProximity]) { [weak self] event in
            self?.read(event)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pressure = nil
    }

    private func read(_ event: NSEvent) {
        switch event.type {
        case .tabletProximity:
            eraser = event.isEnteringProximity && event.pointingDeviceType == .eraser
        case .tabletPoint:
            pressure = Double(event.pressure)
        case .leftMouseDown, .leftMouseDragged:
            pressure = event.subtype == .tabletPoint ? Double(event.pressure) : nil
        default:
            break
        }
    }
}
