import AppKit
import Observation

@MainActor
@Observable
final class LinkMetadataCache {

    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    func image(for urlString: String) -> NSImage? {
        cache[urlString]
    }

    func fetchIfNeeded(for urlString: String) async {
        // Deliberately local-only. Rendering a Smart Link must not fetch the
        // destination URL or disclose its hostname to an icon provider.
    }
}
