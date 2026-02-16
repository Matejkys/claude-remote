import Foundation
import Network

// Lightweight HTTP server using NWListener (Network framework).
// Listens on localhost only for security. Receives CC hook notifications
// via POST /notify, validates the shared secret, and passes parsed
// payloads to the NotificationRouter.
@MainActor
final class HTTPListener {
    private let appState: AppState
    private let settings: Settings
    private let router: NotificationRouter
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.matejkys.ClaudeRemote.HTTPListener")

    init(appState: AppState, settings: Settings, router: NotificationRouter) {
        self.appState = appState
        self.settings = settings
        self.router = router
    }

    // MARK: - Lifecycle

    func start() {
        do {
            let parameters = NWParameters.tcp
            // Bind to localhost only - prevents external access
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(Constants.httpListenerHost),
                port: NWEndpoint.Port(rawValue: Constants.httpListenerPort)!
            )

            listener = try NWListener(using: parameters)

            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerStateChange(state)
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleNewConnection(connection)
                }
            }

            listener?.start(queue: queue)
        } catch {
            print("[HTTPListener] Failed to create listener: \(error)")
            appState.httpListenerRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        appState.httpListenerRunning = false
    }

    // MARK: - State

    private func handleListenerStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            print("[HTTPListener] Listening on \(Constants.httpListenerHost):\(Constants.httpListenerPort)")
            appState.httpListenerRunning = true
        case .failed(let error):
            print("[HTTPListener] Listener failed: \(error)")
            appState.httpListenerRunning = false
            // Attempt to restart after a failure
            listener?.cancel()
            Task {
                try? await Task.sleep(for: .seconds(2))
                await self.start()
            }
        case .cancelled:
            appState.httpListenerRunning = false
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTPRequest(on: connection)
    }

    private func receiveHTTPRequest(on connection: NWConnection) {
        // Receive up to 64KB which is more than enough for a notification payload
        let maxRequestSize = 65536

        connection.receive(minimumIncompleteLength: 1, maximumLength: maxRequestSize) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                print("[HTTPListener] Receive error: \(error)")
                connection.cancel()
                return
            }

            guard let data else {
                if isComplete {
                    connection.cancel()
                }
                return
            }

            Task { @MainActor [weak self] in
                self?.processHTTPData(data, on: connection)
            }
        }
    }

    private func processHTTPData(_ data: Data, on connection: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendResponse(on: connection, statusCode: 400, body: "Invalid request encoding")
            return
        }

        // Parse HTTP request line and headers
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(on: connection, statusCode: 400, body: "Empty request")
            return
        }

        let requestParts = requestLine.components(separatedBy: " ")
        guard requestParts.count >= 2 else {
            sendResponse(on: connection, statusCode: 400, body: "Malformed request line")
            return
        }

        let method = requestParts[0]
        let path = requestParts[1]

        // Only accept POST /notify
        guard method == "POST" && path == "/notify" else {
            sendResponse(on: connection, statusCode: 404, body: "Not found")
            return
        }

        // Extract Authorization header
        let authHeader = lines.first { $0.lowercased().hasPrefix("authorization:") }
        let providedToken = authHeader?
            .components(separatedBy: ":").dropFirst().joined(separator: ":")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "Bearer ", with: "")

        // Validate the bearer token against the stored secret
        let secret = self.settings.httpSecret
        if let secret, !secret.isEmpty {
            guard let providedToken, providedToken == secret else {
                sendResponse(on: connection, statusCode: 401, body: "Unauthorized")
                return
            }
        }

        // Extract JSON body (everything after the blank line separator)
        let bodyStart = requestString.range(of: "\r\n\r\n")
        let body: String
        if let bodyStart {
            body = String(requestString[bodyStart.upperBound...])
        } else if let altStart = requestString.range(of: "\n\n") {
            body = String(requestString[altStart.upperBound...])
        } else {
            sendResponse(on: connection, statusCode: 400, body: "No body found")
            return
        }

        guard let bodyData = body.data(using: .utf8) else {
            sendResponse(on: connection, statusCode: 400, body: "Invalid body encoding")
            return
        }

        // Parse the notification payload
        do {
            let payload = try JSONDecoder().decode(NotificationPayload.self, from: bodyData)

            // Route the notification asynchronously
            Task {
                await self.router.route(payload: payload)
            }

            sendResponse(on: connection, statusCode: 200, body: "OK")
        } catch {
            print("[HTTPListener] JSON decode error: \(error)")
            sendResponse(on: connection, statusCode: 400, body: "Invalid JSON: \(error.localizedDescription)")
        }
    }

    // MARK: - HTTP Response

    private func sendResponse(on connection: NWConnection, statusCode: Int, body: String) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        default: statusText = "Error"
        }

        let response = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: text/plain\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

        let responseData = Data(response.utf8)
        connection.send(content: responseData, completion: .contentProcessed { error in
            if let error {
                print("[HTTPListener] Send response error: \(error)")
            }
            connection.cancel()
        })
    }
}
