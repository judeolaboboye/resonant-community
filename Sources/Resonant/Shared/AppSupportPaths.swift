import Foundation

enum AppSupportPaths {
    static var directoryName: String {
        AppRuntime.applicationSupportDirectoryName
    }

    static func resonantRoot(fileManager: FileManager = .default) -> URL {
        let root: URL
        if let supportDirectory = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first {
            root = supportDirectory.appendingPathComponent(directoryName, isDirectory: true)
        } else {
            root = fileManager.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        }

        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
