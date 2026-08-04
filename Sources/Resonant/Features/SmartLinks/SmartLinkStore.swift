import Foundation
import Defaults
import Observation

struct SmartLink: Codable, Equatable, Identifiable {
    var id: UUID
    var trigger: String   // spoken phrase
    var url: String
    var label: String?    // display label (defaults to trigger)
    var isEnabled: Bool

    init(id: UUID = UUID(), trigger: String, url: String, label: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.trigger = trigger
        self.url = url
        self.label = label
        self.isEnabled = isEnabled
    }
}

extension Defaults.Keys {
    static let smartLinks = Key<[SmartLink]>("smartLinks", default: [], suite: AppDefaults.suite)
}

extension SmartLink: Defaults.Serializable {}

@MainActor
@Observable
final class SmartLinkStore {
    private(set) var links: [SmartLink]

    init() {
        links = Defaults[.smartLinks]
    }

    @discardableResult
    func add(trigger: String, url: String, label: String? = nil, isEnabled: Bool = true) -> SmartLink {
        let link = SmartLink(trigger: trigger, url: url, label: label, isEnabled: isEnabled)
        links.append(link)
        persistLinks()
        return link
    }

    func remove(id: UUID) {
        links.removeAll { $0.id == id }
        persistLinks()
    }

    func update(_ link: SmartLink) {
        if let idx = links.firstIndex(where: { $0.id == link.id }) {
            links[idx] = link
            persistLinks()
        }
    }

    private func persistLinks() {
        Defaults[.smartLinks] = links
        NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
    }

    func mergeWorkspaceLinks(_ workspaceLinks: [SmartLink]) {
        guard links != workspaceLinks else { return }
        links = workspaceLinks
        Defaults[.smartLinks] = links
    }
}
