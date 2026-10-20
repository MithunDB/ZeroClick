import Foundation
import UserNotifications

enum JobNotifications {
    static func requestAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { DiagnosticLog.log("notification access failed: \(error)") }
            else { DiagnosticLog.log("notification access \(granted ? "granted" : "denied")") }
        }
    }

    static func post(_ record: JobRecord) {
        guard AppSettings.shared.notifyOnCompletion else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = record.outcome == .done ? "ZeroClick finished" : "ZeroClick operation failed"
            content.body = record.error ?? record.detail
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil)) { error in
                if let error { DiagnosticLog.log("notification failed: \(error)") }
            }
        }
    }
}
