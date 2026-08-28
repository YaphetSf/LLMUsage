import AppKit
import LLMUsageUI
import SwiftUI

/// LLMUsage's Dock-visible control center. The menu bar tracker stays a separate process, so
/// opening or quitting this window never interrupts tracking. The chromeless window carries
/// the same glass look as the menu bar panel: dark ambient canvas, floating glass panes.
@main
struct LLMUsageApp: App {
    /// Keeps the process alive after the user clicks the red close button — the window
    /// dismisses, the tracker keeps running, and the Dock icon brings the window back.
    @NSApplicationDelegateAdaptor(BackgroundAppDelegate.self) private var appDelegate

    /// A `Window`, not a `WindowGroup`: there is only ever one control center. A group would
    /// also put "New Window" in the File menu, and suppressing that command took the Dock's
    /// reopen behaviour with it — closing the window left the app running with no way back.
    var body: some Scene {
        Window("LLMUsage", id: "control-center") {
            ControlCenterView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 700)
        .windowResizability(.contentMinSize)
    }
}

private final class BackgroundAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
