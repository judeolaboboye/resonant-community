import XCTest
@testable import Resonant

final class LocalAPIServerTests: XCTestCase {

    func testEnforceTokenFilePermissionsRestrictsExistingToken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let tokenURL = directory.appendingPathComponent("api.token")
        try "existing-token".write(to: tokenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokenURL.path)

        LocalAPIServer.enforceTokenFilePermissions(at: tokenURL)

        let permissions = try FileManager.default
            .attributesOfItem(atPath: tokenURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testEnforceTokenFilePermissionsRejectsSymlink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent("api.token")
        try "do-not-read".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertFalse(LocalAPIServer.enforceTokenFilePermissions(at: link))
    }
}
