import Foundation
import ObjCExceptionCatcher

/// Lightweight MCP (Model Context Protocol) server that runs over stdio.
/// Spawned as a child process — communicates via newline-delimited JSON-RPC on stdin/stdout.
@MainActor
final class MCPServer {

    private let dataStore: DataStore
    private let input: FileHandle
    private let output: FileHandle
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var isRunning = false

    init(
        dataStore: DataStore,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        self.dataStore = dataStore
        self.input = input
        self.output = output
        encoder.outputFormatting = [.sortedKeys]
    }

    /// Start reading stdin and dispatching JSON-RPC messages. Blocks until stdin closes.
    func run() async {
        isRunning = true

        // Read lines from stdin
        while isRunning {
            guard let lineData = await readLine(from: input), !lineData.isEmpty else {
                // EOF or empty — client disconnected
                break
            }

            guard let request = try? decoder.decode(JSONRPCRequest.self, from: lineData) else {
                guard writeError(id: nil, error: JSONRPCError(code: -32700, message: "Parse error")) else {
                    break
                }
                continue
            }

            let response = await dispatch(request)
            if let response, !write(response) {
                break
            }
        }

        isRunning = false
    }

    func stop() {
        isRunning = false
    }

    // MARK: - Dispatch

    private func dispatch(_ request: JSONRPCRequest) async -> JSONRPCResponse? {
        switch request.method {

        // MCP lifecycle
        case "initialize":
            let result = MCPInitializeResult(
                protocolVersion: "2024-11-05",
                capabilities: MCPCapabilities(
                    tools: MCPToolsCapability(listChanged: false)
                ),
                serverInfo: MCPServerInfo(name: "resonant", version: "1.0.0")
            )
            return encodeResponse(id: request.id, value: result)

        case "notifications/initialized":
            // No response needed for notifications
            return nil

        case "tools/list":
            let tools = MCPTools.allTools
            return encodeResponse(id: request.id, value: ["tools": tools])

        case "tools/call":
            return await handleToolCall(id: request.id, params: request.params)

        case "ping":
            return JSONRPCResponse(id: request.id, result: .object([:]))

        default:
            return JSONRPCResponse(id: request.id, error: .methodNotFound)
        }
    }

    private func handleToolCall(id: JSONRPCId?, params: JSONValue?) async -> JSONRPCResponse {
        guard let paramsObj = params?.objectValue,
              let toolName = paramsObj["name"]?.stringValue else {
            return JSONRPCResponse(id: id, error: .invalidParams)
        }

        let arguments = paramsObj["arguments"]?.objectValue
        let result = await MCPTools.handle(tool: toolName, arguments: arguments, dataStore: dataStore)

        return encodeResponse(id: id, value: result)
    }

    // MARK: - IO helpers

    private func readLine(from handle: FileHandle) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                while true {
                    guard let byte = Self.readData(ofLength: 1, from: handle), !byte.isEmpty else {
                        // EOF
                        continuation.resume(returning: buffer.isEmpty ? nil : buffer)
                        return
                    }
                    if byte.first == UInt8(ascii: "\n") {
                        continuation.resume(returning: buffer)
                        return
                    }
                    buffer.append(byte)
                }
            }
        }
    }

    private nonisolated static func readData(ofLength length: Int, from handle: FileHandle) -> Data? {
        var exception: NSException?
        return ObjCSafeFileHandleReadData(handle, UInt(length), &exception) as Data?
    }

    private func write(_ response: JSONRPCResponse) -> Bool {
        guard let data = try? encoder.encode(response) else { return false }
        var output = data
        output.append(UInt8(ascii: "\n"))
        var exception: NSException?
        let didWrite = ObjCSafeFileHandleWriteData(self.output, output, &exception)
        if !didWrite {
            isRunning = false
        }
        return didWrite
    }

    private func writeError(id: JSONRPCId?, error: JSONRPCError) -> Bool {
        write(JSONRPCResponse(id: id, error: error))
    }

    private func encodeResponse<T: Encodable>(id: JSONRPCId?, value: T) -> JSONRPCResponse {
        guard let data = try? encoder.encode(value),
              let jsonValue = try? decoder.decode(JSONValue.self, from: data) else {
            return JSONRPCResponse(id: id, error: .internalError("Failed to encode result"))
        }
        return JSONRPCResponse(id: id, result: jsonValue)
    }
}
