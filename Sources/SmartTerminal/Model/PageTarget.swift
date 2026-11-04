import CCef
import CefKit
import Foundation

/// Asks a page's own DevTools agent which DevTools target it is
/// (`Target.getTargetInfo` without a target id answers for the asker). This is how
/// the app knows which target a pane's page is, however many pages open at once.
@MainActor
final class PageTargetQuery {
    private var continuation: CheckedContinuation<String?, Never>?
    private var registration: UnsafeMutablePointer<cef_registration_t>?
    private var messageID: Int32 = 0

    /// The page's target id, or nil if CEF didn't answer within `timeout`.
    static func targetID(of browser: CefBrowser, timeout: TimeInterval = 10) async -> String? {
        let query = PageTargetQuery()
        return await query.run(browser, timeout: timeout)
    }

    private func run(_ browser: CefBrowser, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            continuation = cont
            let started: Bool = browser.withRawHost { host -> Bool in
                let observer = makeObserver()
                registration = host.pointee.add_dev_tools_message_observer?(host, observer)
                var method = cef_string_t()
                let name = "Target.getTargetInfo"
                _ = cef_string_utf8_to_utf16(name, name.utf8.count, &method)
                defer { cef_string_utf16_clear(&method) }
                messageID = host.pointee.execute_dev_tools_method?(host, 0, &method, nil) ?? 0
                return messageID != 0
            } ?? false
            if !started && continuation != nil { finish(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
        }
    }

    fileprivate func received(id: Int32, success: Bool, json: Data) {
        // One command per query, and CEF may answer it before execute_dev_tools_method
        // returns its id: the first result is the answer.
        let info = (try? JSONSerialization.jsonObject(with: json) as? [String: Any])?["targetInfo"] as? [String: Any]
        finish(success ? info?["targetId"] as? String : nil)
    }

    private func finish(_ result: String?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let r = registration {
            r.withMemoryRebound(to: cef_base_ref_counted_t.self, capacity: 1) { _ = $0.pointee.release?($0) }
            registration = nil
        }
        cont.resume(returning: result)
    }

    /// The observer struct CEF calls back on (UI thread = main thread). It holds the
    /// query (CCef's allocator keeps the Swift owner alive until CEF lets go).
    private func makeObserver() -> UnsafeMutablePointer<cef_dev_tools_message_observer_t> {
        let opaque = Unmanaged.passRetained(self as AnyObject).toOpaque()
        let raw = ccef_object_alloc(MemoryLayout<cef_dev_tools_message_observer_t>.stride, opaque) { owner in
            guard let owner else { return }
            Unmanaged<AnyObject>.fromOpaque(owner).release()
        }!
        let observer = raw.assumingMemoryBound(to: cef_dev_tools_message_observer_t.self)
        observer.pointee.on_dev_tools_message = { _, browser, _, _ in
            releaseBrowser(browser)
            return 0 // not handled here: CEF goes on to the result/event callbacks
        }
        observer.pointee.on_dev_tools_method_result = { cefSelf, browser, id, success, result, size in
            releaseBrowser(browser)
            let json = result.map { Data(bytes: $0, count: size) } ?? Data()
            guard let cefSelf, let owner = ccef_object_get_swift(cefSelf) else { return }
            let query = Unmanaged<AnyObject>.fromOpaque(owner).takeUnretainedValue() as? PageTargetQuery
            MainActor.assumeIsolated { query?.received(id: id, success: success != 0, json: json) }
        }
        observer.pointee.on_dev_tools_event = { _, browser, _, _, _ in releaseBrowser(browser) }
        observer.pointee.on_dev_tools_agent_attached = { _, browser in releaseBrowser(browser) }
        observer.pointee.on_dev_tools_agent_detached = { _, browser in releaseBrowser(browser) }
        return observer
    }

}

/// Browsers arrive in callbacks with a reference the callee must drop.
private func releaseBrowser(_ browser: UnsafeMutablePointer<cef_browser_t>?) {
    browser?.withMemoryRebound(to: cef_base_ref_counted_t.self, capacity: 1) { _ = $0.pointee.release?($0) }
}
