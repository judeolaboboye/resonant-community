import XCTest
@testable import Resonant

final class AppResourcesTests: XCTestCase {

    func testResolvedBundleURLPrefersPackagedAppResourcesDirectory() throws {
        let fixture = try BundleFixture()
        defer { fixture.remove() }

        let resolvedURL = AppResources.resolvedBundleURL(
            named: AppResources.appBundleName,
            mainBundleResourceURL: fixture.resourcesURL,
            mainBundleURL: fixture.appURL,
            executableURL: fixture.executableURL
        )

        XCTAssertEqual(resolvedURL?.standardizedFileURL, fixture.bundleURL.standardizedFileURL)
    }

    func testResolvedBundleURLFallsBackToExecutableSiblingForLocalRuns() throws {
        let fixture = try BundleFixture(packagedApp: false)
        defer { fixture.remove() }

        let resolvedURL = AppResources.resolvedBundleURL(
            named: AppResources.appBundleName,
            mainBundleResourceURL: nil,
            mainBundleURL: fixture.workspaceURL,
            executableURL: fixture.executableURL
        )

        XCTAssertEqual(resolvedURL?.standardizedFileURL, fixture.bundleURL.standardizedFileURL)
    }
}

private struct BundleFixture {
    let workspaceURL: URL
    let appURL: URL
    let resourcesURL: URL
    let executableURL: URL
    let bundleURL: URL

    init(packagedApp: Bool = true) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        workspaceURL = rootURL
        appURL = rootURL.appendingPathComponent("Resonant.app", isDirectory: true)
        resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        executableURL = packagedApp
            ? appURL.appendingPathComponent("Contents/MacOS/Resonant")
            : rootURL.appendingPathComponent("Resonant")
        bundleURL = packagedApp
            ? resourcesURL.appendingPathComponent(AppResources.appBundleName, isDirectory: true)
            : rootURL.appendingPathComponent(AppResources.appBundleName, isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(
            atPath: executableURL.path,
            contents: Data(),
            attributes: nil
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: workspaceURL)
    }
}
