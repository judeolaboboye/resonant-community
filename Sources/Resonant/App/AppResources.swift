import Foundation

enum AppResources {
    static let appBundleName = "Resonant_Resonant.bundle"

    static func bundle(named bundleName: String) -> Bundle? {
        guard let bundleURL = resolvedBundleURL(named: bundleName) else {
            return nil
        }

        return Bundle(url: bundleURL) ?? Bundle(path: bundleURL.path)
    }

    static func resolvedBundleURL(
        named bundleName: String,
        mainBundleResourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL
    ) -> URL? {
        let candidates = [
            mainBundleResourceURL?.appendingPathComponent(bundleName, isDirectory: true),
            mainBundleURL.appendingPathComponent("Contents/Resources/\(bundleName)", isDirectory: true),
            executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName, isDirectory: true),
            mainBundleURL.appendingPathComponent(bundleName, isDirectory: true),
        ]

        return candidates
            .compactMap { $0 }
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }
}
