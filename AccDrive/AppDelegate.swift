import AppKit
import FileProvider
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusWindow: NSWindow?

    private let domain = NSFileProviderDomain(
        identifier: AppGroup.domainIdentifier,
        displayName: AppGroup.domainDisplayName
    )

    private var isSignedIn: Bool { TokenStore.load() != nil }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        if AppConfig.shared.mockMode {
            // Demo mode: no sign-in needed. Re-add the domain to clear any
            // cached enumeration so the mock tree shows immediately.
            Task {
                await removeDomain()
                await registerDomain()
            }
        } else if isSignedIn {
            Task { await registerDomain() }
        } else {
            showStatusWindow()
        }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cloud", accessibilityDescription: "AccDrive")
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        if isSignedIn {
            menu.addItem(NSMenuItem(title: "Sign out", action: #selector(signOut), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Open in Finder", action: #selector(openInFinder), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Sign in to Autodesk", action: #selector(signIn), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func signIn() {
        Task { @MainActor in
            do {
                try await AuthManager.shared.signIn()
                // Start from a clean domain so a fresh enumeration repopulates the
                // persistent identifier store (avoids stale/broken cached state).
                await removeDomain()
                await registerDomain()
                statusWindow?.close()
                rebuildMenu()
            } catch {
                presentError(error)
            }
        }
    }

    @objc private func signOut() {
        Task { @MainActor in
            await removeDomain()
            TokenStore.clear()
            IdentifierStore.shared.clear()
            rebuildMenu()
            showStatusWindow()
        }
    }

    @objc private func openInFinder() {
        Task { @MainActor in
            guard let manager = NSFileProviderManager(for: domain) else { return }
            do {
                let url = try await manager.getUserVisibleURL(for: .rootContainer)
                // The CloudStorage URL is outside the app sandbox; getUserVisibleURL
                // returns a security-scoped URL that must be opened within its scope.
                _ = url.startAccessingSecurityScopedResource()
                NSWorkspace.shared.open(url)
            } catch {
                Log.app.error("Cannot resolve Finder URL: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - FileProvider domain

    private func registerDomain() async {
        do {
            try await NSFileProviderManager.add(domain)
            try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer)
            Log.app.info("FileProvider domain registered")
        } catch {
            Log.app.error("Failed to add domain: \(error.localizedDescription, privacy: .public)")
            presentError(error)
        }
    }

    private func removeDomain() async {
        do {
            try await NSFileProviderManager.remove(domain)
            Log.app.info("FileProvider domain removed")
        } catch {
            Log.app.error("Failed to remove domain: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - UI helpers

    private func showStatusWindow() {
        if statusWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "AccDrive"
            window.contentViewController = NSHostingController(rootView: LoginView())
            window.center()
            window.isReleasedWhenClosed = false
            statusWindow = window
        }
        statusWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "AccDrive"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
