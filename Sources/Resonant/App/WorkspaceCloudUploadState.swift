import Foundation

enum WorkspaceCloudUploadState: Equatable {
    case idle(lastSyncedAt: Date?)
    case preparing
    case uploading(completed: Int, total: Int)
    case succeeded(inserted: Int, updated: Int, syncedAt: Date)
    case deleting
    case deleted(deletedCount: Int, deletedAt: Date)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .preparing, .uploading, .deleting:
            true
        case .idle, .succeeded, .deleted, .failed:
            false
        }
    }

    var progressFraction: Double? {
        guard case let .uploading(completed, total) = self, total > 0 else {
            return nil
        }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}
