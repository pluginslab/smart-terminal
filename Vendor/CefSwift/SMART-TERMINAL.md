# CefSwift, vendored

[CefSwift](https://github.com/Rajaniraiyn/CefSwift) (MIT, see LICENSE) at commit
`b18cceef8afaf6686147e19a9239f31c2dd81541`, without its Examples and Tests.

Changed for Smart Terminal:

- `CefBrowser.withRawHost(_:)` (Sources/CefKit/CefBrowser.swift): public access to the
  browser host, so the app can ask a page's own DevTools agent for its target id.
- `do_close` returns 1 and calls the new `CefBrowserDelegate.browserWantsToClose(_:)`
  (Sources/CefKit/BrowserClient.swift, CefBrowserDelegate.swift). CefKit returned 0,
  which makes CEF close the browser's top-level window: for a browser embedded in
  the app's window, a page's `window.close()` closed that whole window.
