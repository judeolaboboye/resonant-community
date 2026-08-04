import Defaults
import Foundation

enum AppRuntime {
    static var distributionFlavor: AppDistribution { AppDistribution.current }
    static var appEnvironment: AppEnvironment { AppEnvironment.current }
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier
            ?? distributionFlavor.defaultBundleIdentifier(for: appEnvironment)
    }
    static var defaultsSuiteName: String {
        distributionFlavor.defaultsSuiteName(
            environment: appEnvironment,
            bundleIdentifier: bundleIdentifier
        )
    }
    static var keychainServiceName: String {
        distributionFlavor.keychainServiceName(
            environment: appEnvironment,
            bundleIdentifier: bundleIdentifier
        )
    }
    static var localIdentitySlug: String {
        distributionFlavor.localIdentitySlug(
            environment: appEnvironment,
            bundleIdentifier: bundleIdentifier
        )
    }
    static var applicationSupportDirectoryName: String {
        distributionFlavor.applicationSupportDirectoryName(
            environment: appEnvironment,
            bundleIdentifier: bundleIdentifier
        )
    }
    static var hostedServicesConfiguration: HostedServicesConfiguration? {
        try? appEnvironment.hostedServicesConfiguration()
    }
    static var hasHostedServices: Bool {
        hostedServicesConfiguration != nil
    }
    static let applicationsDirectoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    static var installedApplicationURL: URL {
        let name = distributionFlavor == .community ? "Resonant Community.app" : "Resonant.app"
        return applicationsDirectoryURL.appendingPathComponent(name, isDirectory: true)
    }

    enum InstallLocationIssue {
        case appTranslocation
        case readOnlyVolume(name: String?)
        case outsideApplications

        var title: String {
            switch self {
            case .appTranslocation:
                return "Move Resonant to Applications"
            case .readOnlyVolume:
                return "Resonant Is Running From a Disk Image"
            case .outsideApplications:
                return "Move Resonant to Applications"
            }
        }

        var message: String {
            switch self {
            case .appTranslocation:
                return "Resonant is running from a protected temporary location. Move it to Applications and relaunch so updates and macOS privacy permissions attach to the installed app."
            case .readOnlyVolume(let name):
                if let name, !name.isEmpty {
                    return "Resonant is running from the read-only volume \"\(name)\". Move it to Applications and relaunch so updates and macOS privacy permissions attach to the installed app."
                }
                return "Resonant is running from a read-only disk image. Move it to Applications and relaunch so updates and macOS privacy permissions attach to the installed app."
            case .outsideApplications:
                return "Resonant is running outside /Applications. Move it to Applications and relaunch so updates and macOS privacy permissions attach to the installed app."
            }
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    static var hasValidMainBundle: Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return false
        }

        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              let bundleVersion = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String,
              !bundleVersion.isEmpty else {
            return false
        }

        return true
    }

    static var supportsUserNotifications: Bool {
        hasValidMainBundle
    }

    static var installLocationIssue: InstallLocationIssue? {
        guard hasValidMainBundle else { return nil }

        let bundleURL = Bundle.main.bundleURL
        if bundleURL.path.contains("/AppTranslocation/") {
            return .appTranslocation
        }

        let resourceValues = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeNameKey])
        if resourceValues?.volumeIsReadOnly == true {
            return .readOnlyVolume(name: resourceValues?.volumeName)
        }

        if Bundle.main.bundleIdentifier == "com.resonance.resonant",
           !bundleURL.standardizedFileURL.path.hasPrefix(applicationsDirectoryURL.path + "/") {
            return .outsideApplications
        }

        return nil
    }
}

enum AppDefaults {
    private static let migrationMarkerKey = "didMigrateToExplicitDefaultsSuite"

    static let suite: UserDefaults = {
        let suite = UserDefaults(suiteName: AppRuntime.defaultsSuiteName) ?? .standard
        migrateLegacyDefaultsIfNeeded(into: suite)
        return suite
    }()

    private static func migrateLegacyDefaultsIfNeeded(into suite: UserDefaults) {
        guard suite.object(forKey: migrationMarkerKey) == nil else {
            return
        }

        let standard = UserDefaults.standard
        for key in managedKeys {
            guard suite.object(forKey: key) == nil,
                  let value = standard.object(forKey: key) else {
                continue
            }

            suite.set(value, forKey: key)
        }

        suite.set(true, forKey: migrationMarkerKey)
    }

    static let managedKeys: Set<String> = SettingsManager.defaultsBackedKeys.union([
        "statsTotalWords",
        "statsTotalDictations",
        "statsStreakDays",
        "statsLastUsedDate",
        "statsLongestDictation",
        "statsLongestStreakDays",
        "analyticsInstallDate",
        "analyticsLaunchCount",
        "analyticsLastActiveDate",
        "streakLastDictationDate",
        "streakCurrentCount",
        "streakHighWater",
        "smartLinks",
        "meetingWebhookSecret",
    ])
}
