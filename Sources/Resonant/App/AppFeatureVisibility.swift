enum AppFeatureVisibility {
    static let cloudSync = false
    static let dispatch = false
    static var hostedServices: Bool { AppRuntime.hasHostedServices }
}
