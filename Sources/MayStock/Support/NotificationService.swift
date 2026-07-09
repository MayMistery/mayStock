import AppKit
import UserNotifications

/// Alert delivery. `UNUserNotificationCenter` requires a real app bundle —
/// when running unbundled (`swift run`), falls back to sound + `osascript`
/// banner so development still gives feedback.
@MainActor
final class NotificationService {
    private var authorizationRequested = false
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    func post(title: String, body: String, sound: Bool) {
        guard isBundled else {
            postFallback(title: title, body: body, sound: sound)
            return
        }
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if sound { content.sound = .default }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
        if authorizationRequested {
            deliver()
        } else {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                if granted { DispatchQueue.main.async { deliver() } }
            }
        }
    }

    private func postFallback(title: String, body: String, sound: Bool) {
        if sound { NSSound(named: "Glass")?.play() }
        let escaped = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(escaped(body))\" with title \"\(escaped(title))\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
