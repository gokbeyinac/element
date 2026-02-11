import SwiftUI
import AppKit

@main
struct ElementApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var apiServer = ElementAPIServer()
    @StateObject private var claudeSession = ClaudeCodeSession()
    @StateObject private var devServerManager = DevServerManager()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .environmentObject(claudeSession)
                .environmentObject(devServerManager)
                .frame(minWidth: 1000, minHeight: 700)
                .onAppear {
                    appState.loadProjects()
                    checkAccessibilityPermission()
                    apiServer.start(appState: appState, devServerManager: devServerManager)
                    // Auto-start Claude session for the initial project
                    startClaudeSessionIfNeeded()
                }
                .onDisappear {
                    devServerManager.stopAll()
                }
                .task {
                    await monitorBridgeStatus()
                }
                .onChange(of: appState.selectedProjectID) { _, _ in
                    startClaudeSessionIfNeeded()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            appCommands
        }

        Settings {
            SettingsView()
        }
    }

    // MARK: - Commands

    private var appCommands: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Toggle Inspector") {
                appState.inspectionEnabled.toggle()
            }
            .keyboardShortcut("i", modifiers: .command)

            Button("Clear Selection") {
                appState.clearSelection()
            }
            .keyboardShortcut(.escape, modifiers: [])

            Divider()

            Button("Copy as Prompt") {
                if let element = appState.selectedElement {
                    ClipboardService.copy(element, format: .prompt)
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(appState.selectedElement == nil)

            Button("Copy File Path") {
                if let element = appState.selectedElement {
                    ClipboardService.copy(element, format: .filePath)
                }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(appState.selectedElement == nil)

            Divider()

            Button("Clear History") {
                appState.elementHistory.clear()
            }
            .disabled(appState.elementHistory.isEmpty)
        }
    }

    // MARK: - Accessibility Permission Check

    private func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        NSLog("[Element] AXIsProcessTrusted = %@", trusted ? "YES" : "NO")

        if !trusted {
            // Prompt macOS to show the Accessibility permission dialog
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)

            NSLog("[Element] Accessibility permission NOT granted. Prompting user.")
        } else {
            NSLog("[Element] Accessibility permission granted.")
        }
    }

    // MARK: - Claude Code Session

    private func startClaudeSessionIfNeeded() {
        guard let project = appState.selectedProject else { return }
        // Don't restart if already running for the same project
        if claudeSession.status.isReady,
           claudeSession.currentProjectPath == project.path {
            return
        }
        // Stop existing session if project changed
        if claudeSession.status != .idle {
            claudeSession.stop()
        }
        claudeSession.start(projectPath: project.path)
    }

    // MARK: - Bridge Status Monitor

    private func monitorBridgeStatus() async {
        let client = BridgeClient()

        while !Task.isCancelled {
            do {
                let status = try await client.getStatus()
                let bridgeStatus = BridgeStatus(
                    connection: .connected,
                    idle: status.idle,
                    queueLength: status.queue_length,
                    childAlive: status.child_alive
                )
                appState.updateBridgeStatus(bridgeStatus)
            } catch {
                appState.setBridgeConnection(.disconnected)
            }

            try? await Task.sleep(for: .seconds(3))
        }
    }
}
