import AppKit
import CCefAppKit

MainActor.assumeIsolated {
    // Chromium needs its NSApplication subclass from the very first event, even
    // though Chromium itself only starts when a tab first opens a page in it.
    CEFApplication.install()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
