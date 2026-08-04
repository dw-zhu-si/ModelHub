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

final class ModelHubApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            ModelHubWindowController.hideMainWindows()
        }
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
        model.bootstrap(initializeSecrets: false)
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
                    model.flushPendingPersistence()
                }
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1_180, height: 760)
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

        MenuBarExtra("ModelHub", systemImage: "point.3.connected.trianglepath.dotted") {
            Button("打开 ModelHub") {
                ModelHubWindowController.showMainWindow()
            }
            Divider()
            Text(mhLocalized(model.isServerRunning ? "本地 API 已运行" : "本地 API 未运行"))
            Button(mhLocalized(model.isServerRunning ? "停止本地 API" : "启动本地 API")) {
                model.isServerRunning ? model.stopServer() : model.startServer()
            }
            Divider()
            Button("退出 ModelHub") {
                NSApplication.shared.terminate(nil)
            }
        }
        .environment(\.locale, model.interfaceLocale)
    }
}
