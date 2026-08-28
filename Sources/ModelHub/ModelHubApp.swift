import SwiftUI

@MainActor
private enum ModelHubWindowController {
    static func hideMainWindows() {
        NSApplication.shared.windows
            .filter { $0.canBecomeKey && !($0 is NSPanel) }
            .forEach { $0.orderOut(nil) }
    }

    static func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: {
            $0.canBecomeKey && !($0 is NSPanel)
        }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
final class ModelHubApplicationDelegate: NSObject, NSApplicationDelegate {
    private static let hasCompletedFirstLaunchKey = "hasCompletedFirstLaunch"
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        installStatusItem()

        let defaults = UserDefaults.standard
        let isFirstLaunch = !defaults.bool(forKey: Self.hasCompletedFirstLaunchKey)
        defaults.set(true, forKey: Self.hasCompletedFirstLaunchKey)
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let visualInspection = environment[
            "MODELHUB_VISUAL_INSPECTION"
        ] == "1"
        if environment["MODELHUB_VISUAL_APPEARANCE"] == "dark" {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        } else if environment["MODELHUB_VISUAL_APPEARANCE"] == "light" {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        }
        #else
        let visualInspection = false
        #endif
        if isFirstLaunch || visualInspection {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600)) {
                ModelHubWindowController.showMainWindow()
            }
        } else {
            DispatchQueue.main.async {
                ModelHubWindowController.hideMainWindows()
            }
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "point.3.connected.trianglepath.dotted",
                accessibilityDescription: "ModelHub"
            )
            button.image?.isTemplate = true
            button.toolTip = "ModelHub"
        }

        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: String(localized: "打开 ModelHub"),
            action: #selector(openMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: String(localized: "退出 ModelHub"),
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func openMainWindow() {
        ModelHubWindowController.showMainWindow()
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        ModelHubWindowController.showMainWindow()
        return true
    }
}

@main
struct ModelHubApp: App {
    @NSApplicationDelegateAdaptor(ModelHubApplicationDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let visualDemo = environment["MODELHUB_VISUAL_DEMO"] == "1"
        if visualDemo {
            // Visual-review fixtures must stay independent from the user's
            // saved configuration and Keychain. This also makes screenshot
            // capture deterministic and prevents authorization prompts.
            model.enterReviewDemoMode()
            if environment["MODELHUB_VISUAL_STRESS"] == "1" {
                model.prepareProviderLayoutStressDemo()
            }
        } else {
            model.bootstrap(initializeSecrets: false)
        }
        if let page = environment["MODELHUB_VISUAL_PAGE"],
           let selection = SidebarItem(rawValue: page)
        {
            model.selection = selection
        }
        #else
        model.bootstrap(initializeSecrets: false)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environment(\.locale, model.interfaceLocale)
                .onAppear {
                    model.restoreRequestedLaunchAtLogin()
                    model.refreshLaunchAtLoginStatus()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.stopModelProxyRuntime()
                    model.flushPendingPersistence(waitUntilFinished: true)
                }
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1_240, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
                Button(mhLocalized(model.isServerRunning ? "停止本地 API 服务" : "启动本地 API 服务")) {
                    model.isServerRunning ? model.stopServer() : model.startServer()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environment(\.locale, model.interfaceLocale)
                .frame(width: 680, height: 720)
        }

    }
}
