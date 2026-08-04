import Foundation
import XCTest
@testable import Resonant

final class MCPServerTests: XCTestCase {
    @MainActor
    func testInitializeWritesResponseToInjectedOutput() async throws {
        let input = Pipe()
        let output = Pipe()
        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\n"
        input.fileHandleForWriting.write(Data(request.utf8))
        input.fileHandleForWriting.closeFile()

        let server = MCPServer(
            dataStore: DataStore(),
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting
        )

        await server.run()
        output.fileHandleForWriting.closeFile()

        let responseData = output.fileHandleForReading.readDataToEndOfFile()
        let response = try XCTUnwrap(String(data: responseData, encoding: .utf8))
        XCTAssertTrue(response.contains(#""id":1"#))
        XCTAssertTrue(response.contains(#""name":"resonant""#))
        XCTAssertTrue(response.contains(#""protocolVersion":"2024-11-05""#))
    }

    @MainActor
    func testClosedOutputPipeEndsServerWithoutObjectiveCCrash() async {
        let input = Pipe()
        let output = Pipe()
        output.fileHandleForReading.closeFile()

        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\n"
        input.fileHandleForWriting.write(Data(request.utf8))
        input.fileHandleForWriting.closeFile()

        let server = MCPServer(
            dataStore: DataStore(),
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting
        )

        await server.run()
    }
}
