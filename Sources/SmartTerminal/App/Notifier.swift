import AppKit
import SmartTerminalCore
import UserNotifications

/// macOS notifications for Claude sessions that need you, plus the Dock badge.
/// Clicking a notification jumps to its tab.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private weak var model: AppModel?
    private let center = UNUserNotificationCenter.current()

    init(model: AppModel) {
        self.model = model
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("SmartTerminal: notifications not authorized: \(error)") }
            else if !granted { NSLog("SmartTerminal: notifications declined") }
        }
    }

    enum Kind { case finished, needsInput }

    func post(_ kind: Kind, tabID: UUID, title: String, group: String?, detail: String?) {
        let content = UNMutableNotificationContent()
        switch kind {
        case .finished: content.title = "Claude finished"
        case .needsInput: content.title = "Claude needs you"
        }
        content.subtitle = [group, title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        if let detail, !detail.isEmpty { content.body = String(detail.prefix(180)) }
        content.sound = kind == .needsInput ? .default : nil
        content.threadIdentifier = tabID.uuidString
        content.userInfo = ["tabID": tabID.uuidString]
        // One notification per tab: a newer one replaces the older.
        center.add(UNNotificationRequest(identifier: tabID.uuidString, content: content, trigger: nil)) { error in
            if let error { NSLog("SmartTerminal: notification failed: \(error)") }
        }
    }

    func clear(tabID: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: [tabID.uuidString])
    }

    func setBadge(_ count: Int) {
        let label = count > 0 ? "\(count)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even while the app is active (we only post for tabs you can't see).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["tabID"] as? String).flatMap(UUID.init)
        await MainActor.run { [weak self] in
            if let id { self?.model?.reveal(tabID: id) }
        }
    }
}
