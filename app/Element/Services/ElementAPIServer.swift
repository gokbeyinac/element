import Foundation
import Network

/// Lightweight HTTP server on localhost:7749 for MCP integration.
/// Exposes Element app state so the MCP server can query it.
@MainActor
final class ElementAPIServer: ObservableObject {
    @Published private(set) var isRunning = false

    private var listener: NWListener?
    private weak var appState: AppState?
    private weak var devServerManager: DevServerManager?

    static let port: UInt16 = 7749

    func start(appState: AppState, devServerManager: DevServerManager) {
        self.appState = appState
        self.devServerManager = devServerManager

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            guard let listenPort = NWEndpoint.Port(rawValue: Self.port) else {
                NSLog("[ElementAPI] Invalid port: \(Self.port)")
                return
            }
            listener = try NWListener(using: params, on: listenPort)
            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        NSLog("[ElementAPI] Server listening on localhost:\(Self.port)")
                    case .failed(let error):
                        self?.isRunning = false
                        NSLog("[ElementAPI] Server failed: \(error)")
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleConnection(connection)
                }
            }

            listener?.start(queue: .global(qos: .userInitiated))
        } catch {
            NSLog("[ElementAPI] Failed to create listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            if let error {
                NSLog("[ElementAPI] Receive error: \(error)")
                connection.cancel()
                return
            }

            guard let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            Task { @MainActor in
                self?.routeRequest(request, connection: connection)
            }
        }
    }

    // MARK: - Routing

    @MainActor
    private func routeRequest(_ raw: String, connection: NWConnection) {
        let (method, path) = parseRequestLine(raw)
        let body = parseRequestBody(raw)

        switch (method, path) {
        case ("GET", "/health"):
            sendResponse(connection: connection, status: 200, body: healthResponse())
        case ("GET", "/selection"):
            sendResponse(connection: connection, status: 200, body: selectionResponse())
        case ("GET", "/context"):
            sendResponse(connection: connection, status: 200, body: contextResponse())
        case ("GET", "/projects"):
            sendResponse(connection: connection, status: 200, body: projectsResponse())

        // Project management
        case ("POST", "/projects"):
            let (status, json) = addProjectHandler(body: body)
            sendResponse(connection: connection, status: status, body: json)
        case ("DELETE", _) where path.hasPrefix("/projects/"):
            let idString = String(path.dropFirst("/projects/".count))
            let (status, json) = removeProjectHandler(idString: idString)
            sendResponse(connection: connection, status: status, body: json)

        // Dev server management
        case ("POST", "/dev-server/start"):
            let (status, json) = startDevServerHandler(body: body)
            sendResponse(connection: connection, status: status, body: json)
        case ("POST", "/dev-server/stop"):
            let (status, json) = stopDevServerHandler(body: body)
            sendResponse(connection: connection, status: status, body: json)
        case ("GET", "/dev-server/status"):
            sendResponse(connection: connection, status: 200, body: devServerStatusResponse())

        // CORS preflight
        case ("OPTIONS", _):
            sendResponse(connection: connection, status: 200, body: #"{"ok":true}"#)

        default:
            sendResponse(connection: connection, status: 404, body: #"{"error":"not_found"}"#)
        }
    }

    // MARK: - Route Handlers

    @MainActor
    private func healthResponse() -> String {
        let running = isRunning
        return #"{"status":"ok","running":\#(running),"version":"1.0.0"}"#
    }

    @MainActor
    private func selectionResponse() -> String {
        guard let element = appState?.selectedElement else {
            return #"{"selected":false}"#
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(SelectionPayload(element: element)),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"selected":false,"error":"encoding_failed"}"#
        }
        return json
    }

    @MainActor
    private func contextResponse() -> String {
        guard let state = appState else {
            return #"{"error":"no_state"}"#
        }

        let prompt = state.renderedPrompt ?? ""
        let projectName = state.selectedProject?.name ?? ""
        let projectPath = state.selectedProject?.path ?? ""
        let platform = state.selectedProject?.platform.rawValue ?? ""
        let hasElement = state.selectedElement != nil
        let inspecting = state.inspectionEnabled

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let context = ContextPayload(
            hasSelectedElement: hasElement,
            renderedPrompt: prompt,
            projectName: projectName,
            projectPath: projectPath,
            platform: platform,
            inspectionEnabled: inspecting,
            element: hasElement ? state.selectedElement : nil
        )

        guard let data = try? encoder.encode(context),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"error":"encoding_failed"}"#
        }
        return json
    }

    @MainActor
    private func projectsResponse() -> String {
        guard let state = appState else {
            return #"{"projects":[]}"#
        }

        let projects = state.projects.map { p in
            ProjectPayload(
                id: p.id.uuidString,
                name: p.name,
                path: p.path,
                platform: p.platform.rawValue,
                url: p.url
            )
        }

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(ProjectsPayload(projects: projects)),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"projects":[]}"#
        }
        return json
    }

    // MARK: - Project Management Handlers

    @MainActor
    private func addProjectHandler(body: String?) -> (Int, String) {
        guard let state = appState else {
            return (500, #"{"error":"no_state"}"#)
        }

        guard let body,
              let data = body.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AddProjectPayload.self, from: data) else {
            return (400, #"{"error":"invalid_body","message":"Expected JSON with name, path, platform, url fields"}"#)
        }

        let platformType: PlatformType
        switch payload.platform.lowercased() {
        case "web": platformType = .web
        case "reactnative", "react-native", "react_native": platformType = .reactNative
        case "swiftui", "swift-ui", "swift_ui": platformType = .swiftUI
        case "uikit", "ui-kit", "ui_kit": platformType = .uiKit
        default:
            return (400, #"{"error":"invalid_platform","message":"Platform must be: web, reactNative, swiftUI, or uiKit"}"#)
        }

        let project = ProjectConfig(
            id: UUID(),
            name: payload.name,
            path: payload.path,
            platform: platformType,
            url: payload.url ?? "",
            port: payload.port
        )

        state.addProject(project)
        return (201, #"{"success":true,"id":"\#(project.id.uuidString)","name":"\#(project.name)"}"#)
    }

    @MainActor
    private func removeProjectHandler(idString: String) -> (Int, String) {
        guard let state = appState else {
            return (500, #"{"error":"no_state"}"#)
        }

        guard let uuid = UUID(uuidString: idString) else {
            return (400, #"{"error":"invalid_id"}"#)
        }

        guard state.projects.contains(where: { $0.id == uuid }) else {
            return (404, #"{"error":"project_not_found"}"#)
        }

        devServerManager?.stop(projectID: uuid)
        state.removeProject(id: uuid)
        return (200, #"{"success":true}"#)
    }

    // MARK: - Dev Server Handlers

    @MainActor
    private func startDevServerHandler(body: String?) -> (Int, String) {
        guard let state = appState, let dsm = devServerManager else {
            return (500, #"{"error":"no_state"}"#)
        }

        // If body has project_id, use that; otherwise use selected project
        let project: ProjectConfig?
        if let body, let data = body.data(using: .utf8),
           let payload = try? JSONDecoder().decode(DevServerPayload.self, from: data),
           let id = UUID(uuidString: payload.project_id ?? "") {
            project = state.projects.first { $0.id == id }
        } else {
            project = state.selectedProject
        }

        guard let proj = project else {
            return (400, #"{"error":"no_project","message":"No project selected or found"}"#)
        }

        dsm.start(project: proj)
        return (200, #"{"success":true,"project":"\#(proj.name)","command":"\#(DevServerManager.inferCommand(from: proj.url))"}"#)
    }

    @MainActor
    private func stopDevServerHandler(body: String?) -> (Int, String) {
        guard let state = appState, let dsm = devServerManager else {
            return (500, #"{"error":"no_state"}"#)
        }

        let project: ProjectConfig?
        if let body, let data = body.data(using: .utf8),
           let payload = try? JSONDecoder().decode(DevServerPayload.self, from: data),
           let id = UUID(uuidString: payload.project_id ?? "") {
            project = state.projects.first { $0.id == id }
        } else {
            project = state.selectedProject
        }

        guard let proj = project else {
            return (400, #"{"error":"no_project","message":"No project selected or found"}"#)
        }

        dsm.stop(projectID: proj.id)
        return (200, #"{"success":true,"project":"\#(proj.name)"}"#)
    }

    @MainActor
    private func devServerStatusResponse() -> String {
        guard let state = appState, let dsm = devServerManager else {
            return #"{"servers":[]}"#
        }

        var servers: [[String: Any]] = []
        for (projectID, serverProcess) in dsm.runningServers {
            let projectName = state.projects.first(where: { $0.id == projectID })?.name ?? "unknown"
            servers.append([
                "project_id": projectID.uuidString,
                "project_name": projectName,
                "command": serverProcess.command,
                "running": serverProcess.process.isRunning,
                "started_at": ISO8601DateFormatter().string(from: serverProcess.startedAt)
            ])
        }

        guard let data = try? JSONSerialization.data(withJSONObject: ["servers": servers]),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"servers":[]}"#
        }
        return json
    }

    // MARK: - HTTP Helpers

    private func parseRequestLine(_ raw: String) -> (String, String) {
        let firstLine = raw.split(separator: "\r\n").first ?? raw.split(separator: "\n").first ?? Substring(raw)
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return ("GET", "/") }
        return (String(parts[0]), String(parts[1]))
    }

    private func parseRequestBody(_ raw: String) -> String? {
        // HTTP body comes after double CRLF
        if let range = raw.range(of: "\r\n\r\n") {
            let body = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : body
        }
        if let range = raw.range(of: "\n\n") {
            let body = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : body
        }
        return nil
    }

    private func sendResponse(connection: NWConnection, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Error"
        }

        let response = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Access-Control-Allow-Origin: http://localhost\r
        Connection: close\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - API Payloads

private struct SelectionPayload: Encodable {
    let selected: Bool = true
    let element: ElementSummary

    init(element: ElementInfo) {
        self.element = ElementSummary(element: element)
    }
}

private struct ElementSummary: Encodable {
    let platform: String
    let componentName: String
    let tagName: String
    let textContent: String
    let filePath: String
    let lineNumber: Int
    let columnNumber: Int?
    let codeSnippet: String
    let componentTree: [String]
    let frame: FrameSummary
    let accessibilityIdentifier: String
    let childrenSummary: [String]

    init(element: ElementInfo) {
        self.platform = element.platform.rawValue
        self.componentName = element.componentName
        self.tagName = element.tagName
        self.textContent = element.textContent ?? ""
        self.filePath = element.filePath
        self.lineNumber = element.lineNumber
        self.columnNumber = element.columnNumber
        self.codeSnippet = element.codeSnippet
        self.componentTree = element.componentTree
        self.frame = FrameSummary(
            x: element.elementRect.x,
            y: element.elementRect.y,
            width: element.elementRect.width,
            height: element.elementRect.height
        )
        self.accessibilityIdentifier = element.accessibilityIdentifier
        self.childrenSummary = element.childrenSummary
    }
}

private struct FrameSummary: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct ContextPayload: Encodable {
    let hasSelectedElement: Bool
    let renderedPrompt: String
    let projectName: String
    let projectPath: String
    let platform: String
    let inspectionEnabled: Bool
    let element: ElementInfo?
}

private struct ProjectPayload: Encodable {
    let id: String
    let name: String
    let path: String
    let platform: String
    let url: String
}

private struct ProjectsPayload: Encodable {
    let projects: [ProjectPayload]
}

private struct AddProjectPayload: Decodable {
    let name: String
    let path: String
    let platform: String
    let url: String?
    let port: Int?
}

private struct DevServerPayload: Decodable {
    let project_id: String?
}
