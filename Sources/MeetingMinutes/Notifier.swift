import AppKit
import UserNotifications

/// Native macOS notifications. Clicking one opens the minutes file.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var center: UNUserNotificationCenter? {
        // Without an app bundle (command-line mode) UNUserNotificationCenter is not available.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp() {
        center?.delegate = self
    }

    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.error("Notification permission: \(error.localizedDescription)")
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus? {
        guard let center else { return nil }
        return await center.notificationSettings().authorizationStatus
    }

    func isAuthorized() async -> Bool {
        let status = await authorizationStatus()
        return status == .authorized || status == .provisional
    }

    static func describe(_ status: UNAuthorizationStatus?) -> String {
        switch status {
        case .authorized, .provisional: return "allowed"
        case .denied: return "off"
        case .notDetermined: return "not requested yet"
        default: return "unavailable"
        }
    }

    func post(title: String, body: String, fileURL: URL? = nil, sound: Bool = true) {
        guard let center else {
            Log.info("[notification] \(title) — \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        if let fileURL { content.userInfo = ["path": fileURL.path] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error { Log.error("Could not show notification: \(error.localizedDescription)") }
        }
    }

    // Show the banner even while the app is "in front".
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["path"] as? String else { return }
        await MainActor.run {
            _ = NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}
