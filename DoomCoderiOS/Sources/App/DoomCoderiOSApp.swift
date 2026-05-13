import SwiftUI
import CloudKit
import UserNotifications

@main
struct DoomCoderiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sessionStore = SessionStore.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(sessionStore)
                .preferredColorScheme(.dark)
                .onOpenURL { url in handleDeepLink(url) }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "doomcoder",
              url.host == "session",
              let key = url.pathComponents.dropFirst().first else { return }
        SessionStore.shared.focusedSessionKey = key
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationDispatcher.registerCategories()
        // Skip heavy CloudKit/notification setup when running under XCTest.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return true }
        writeAgentIconsToAppGroup()
        Task { @MainActor in
            await NotificationPermissions.request()
            await CloudKitSubscriptionHandler.shared.registerAll()
            await DevicePresenceUpdater.shared.heartbeat()
            await SettingsSyncer.shared.pull()
        }
        application.registerForRemoteNotifications()
        return true
    }

    private func writeAgentIconsToAppGroup() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.doomcoder.ios"
        ) else { return }
        for brand in AgentBrand.allKnown {
            let dest = container.appendingPathComponent("icon-\(brand.agentKey).png")
            guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
            guard let image = UIImage(named: brand.iconAssetName),
                  let data = image.pngData() else { continue }
            try? data.write(to: dest, options: .atomic)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await ApprovalResponder.shared.userNotificationCenter(center, didReceive: response)
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            await PushReceiver.shared.handle(userInfo: userInfo)
            completionHandler(.newData)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

enum NotificationPermissions {
    static func request() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
}
