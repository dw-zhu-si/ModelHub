import SwiftUI

@MainActor
enum ModelHubWindowPresentationPlan: Equatable {
    case showExisting
    case waitForMainWindow
    case createFallbackWindow
}

@MainActor
final class ModelHubMainWindowDelegateProxy: NSObject, NSWindowDelegate {
    nonisolated(unsafe) private let forwardedDelegate: (any NSWindowDelegate)?

    init(forwarding delegate: (any NSWindowDelegate)?) {
        forwardedDelegate = delegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if ModelHubWindowController.isTerminationRequested {
            return true
        }
        sender.orderOut(nil)
        DispatchQueue.main.async {
            let hasVisibleWindow = NSApplication.shared.windows.contains {
                $0.isVisible && $0.canBecomeKey && !($0 is NSPanel)
            }
            if !hasVisibleWindow {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector)
            || (forwardedDelegate?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardedDelegate?.responds(to: selector) == true {
            return forwardedDelegate
        }
        return super.forwardingTarget(for: selector)
    }
}

@MainActor
enum ModelHubWindowController {
    private static let presentationRetryDelay = DispatchTimeInterval.milliseconds(100)
    private static let presentationRetryLimit = 12
    private static var makeFallbackWindow: (() -> NSWindow)?
    private static var mainWindow: NSWindow?
    private static var mainWindowDelegate: ModelHubMainWindowDelegateProxy?
    private static var pendingPresentation: DispatchWorkItem?
    private(set) static var isTerminationRequested = false

    static func registerFallbackWindowFactory(_ factory: @escaping () -> NSWindow) {
        makeFallbackWindow = factory
    }

    static func presentationPlan(
        hasExistingWindow: Bool,
        remainingAttempts: Int,
        canCreateFallbackWindow: Bool
    ) -> ModelHubWindowPresentationPlan {
        if hasExistingWindow {
            return .showExisting
        }
        if remainingAttempts > 0 {
            return .waitForMainWindow
        }
        return canCreateFallbackWindow ? .createFallbackWindow : .waitForMainWindow
    }

    static func registerMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        if mainWindow != nil {
            window.orderOut(nil)
            return
        }
        let delegate = ModelHubMainWindowDelegateProxy(forwarding: window.delegate)
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        mainWindow = window
        mainWindowDelegate = delegate
    }

    static func prepareForTermination() {
        isTerminationRequested = true
        pendingPresentation?.cancel()
        pendingPresentation = nil
    }

    static func hideMainWindows() {
        let windows = NSApplication.shared.windows
            .filter { $0.canBecomeKey && !($0 is NSPanel) }
        windows.forEach { $0.orderOut(nil) }
    }

    static func showMainWindow() {
        pendingPresentation?.cancel()
        pendingPresentation = nil
        attemptToShowMainWindow(remainingAttempts: presentationRetryLimit)
    }

    private static func attemptToShowMainWindow(remainingAttempts: Int) {
        let window = mainWindow ?? NSApplication.shared.windows.first(where: {
            $0.canBecomeKey && !($0 is NSPanel)
        })
        switch presentationPlan(
            hasExistingWindow: window != nil,
            remainingAttempts: remainingAttempts,
            canCreateFallbackWindow: makeFallbackWindow != nil
        ) {
        case .showExisting:
            if let window {
                registerMainWindow(window)
                activateForMainWindow()
                window.makeKeyAndOrderFront(nil)
            }
            pendingPresentation = nil
        case .waitForMainWindow:
            guard remainingAttempts > 0, !isTerminationRequested else {
                pendingPresentation = nil
                return
            }
            let workItem = DispatchWorkItem {
                attemptToShowMainWindow(remainingAttempts: remainingAttempts - 1)
            }
            pendingPresentation = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + presentationRetryDelay,
                execute: workItem
            )
        case .createFallbackWindow:
            guard let makeFallbackWindow, !isTerminationRequested else { return }
            let fallbackWindow = makeFallbackWindow()
            registerMainWindow(fallbackWindow)
            activateForMainWindow()
            fallbackWindow.makeKeyAndOrderFront(nil)
            pendingPresentation = nil
        }
    }

    private static func activateForMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct ModelHubWindowCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowCaptureView {
        WindowCaptureView()
    }

    func updateNSView(_ nsView: WindowCaptureView, context: Context) {
        nsView.registerWindowIfAvailable()
    }

    @MainActor
    final class WindowCaptureView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerWindowIfAvailable()
        }

        func registerWindowIfAvailable() {
            guard let window else { return }
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                ModelHubWindowController.registerMainWindow(window)
            }
        }
    }
}

private struct ModelHubRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ContentView()
            .environmentObject(model)
            .environment(\.locale, model.interfaceLocale)
            .background(
                ModelHubWindowCapture()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            )
            .onAppear {
                model.restoreRequestedLaunchAtLogin()
                model.refreshLaunchAtLoginStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                model.stopModelProxyRuntime()
                model.stopMobileAccess()
                model.flushPendingPersistence(waitUntilFinished: true)
            }
            .frame(minWidth: 980, minHeight: 680)
    }
}

@MainActor
private enum ModelHubMainWindowFactory {
    private static let frameAutosaveName = "ModelHubMainWindow"

    static func make(model: AppModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_240, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ModelHub"
        window.identifier = NSUserInterfaceItemIdentifier("modelhub-main")
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 980, height: 680)
        window.contentViewController = NSHostingController(
            rootView: ModelHubRootView(model: model)
        )
        if !window.setFrameUsingName(frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(frameAutosaveName)
        return window
    }
}

@MainActor
final class ModelHubApplicationDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        installStatusItem()

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
        let presentationDelay: DispatchTimeInterval = visualInspection
            ? .milliseconds(600)
            : .milliseconds(150)
        #else
        let presentationDelay: DispatchTimeInterval = .milliseconds(150)
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + presentationDelay) {
            ModelHubWindowController.showMainWindow()
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
        ModelHubWindowController.prepareForTermination()
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        ModelHubWindowController.prepareForTermination()
        return .terminateNow
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
        ModelHubWindowController.registerFallbackWindowFactory {
            ModelHubMainWindowFactory.make(model: model)
        }
    }

    var body: some Scene {
        WindowGroup {
            ModelHubRootView(model: model)
        }
        .defaultSize(width: 1_240, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(mhLocalized("检查更新…")) {
                    model.checkForApplicationUpdate()
                }
                .disabled(
                    model.applicationReleaseChannel == .local
                        || model.isCheckingForApplicationUpdate
                )
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
