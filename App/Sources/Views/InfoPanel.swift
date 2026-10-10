import AppKit
import SwiftUI

/// Window › Info (⌘I) as a floating panel, as Info is in Photos and the
/// inspector in Finder (⌥⌘I): it stays above the main window without taking
/// focus from it, so arrows, shortcuts and clicks keep going to the photos,
/// and it follows the selection. ⌘I shows and hides it. It becomes the key
/// window only while a field in it is being typed in, and hides while
/// Develop is in the background.
@MainActor
final class InfoPanel: NSObject, NSWindowDelegate {
    static let shared = InfoPanel()
    private var panel: NSPanel?
    /// for the View menu's title
    private(set) var isVisible = false {
        didSet { NotificationCenter.default.post(name: Self.visibilityChanged, object: nil) }
    }
    static let visibilityChanged = Notification.Name("InfoPanelVisibilityChanged")

    func toggle(model: EditorModel) {
        if let panel, panel.isVisible { hide() } else { show(model: model) }
    }

    func show(model: EditorModel) {
        let panel = self.panel ?? make(model: model)
        self.panel = panel
        // in front, but the main window stays key
        panel.orderFront(nil)
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    private func make(model: EditorModel) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 620),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Info"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true     // only a text field makes it key
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.minSize = NSSize(width: 280, height: 360)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: MetadataWindow()
            .environment(model)
            .preferredColorScheme(.dark))
        if !panel.setFrameUsingName("InfoPanel") {
            // beside the main window's right edge, as Photos places Info
            if let main = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) ?? NSApp.mainWindow {
                let f = main.frame
                panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - 340, y: f.maxY - 80))
            } else {
                panel.center()
            }
        }
        panel.setFrameAutosaveName("InfoPanel")
        return panel
    }

    func windowWillClose(_ notification: Notification) { isVisible = false }
}
