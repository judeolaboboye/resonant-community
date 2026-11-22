import LocalAuthentication

/// Gates whether a screen-awareness request may proceed to the full-agent
/// `claude` CLI call, using Touch ID (falling back to the device password
/// automatically if Touch ID isn't available) via `LAContext`.
///
/// Important honesty about what this actually guarantees: headless
/// `claude -p` runs its entire tool sequence autonomously in one shot, with
/// no external checkpoint between individual tool calls — there is no hook
/// to pause mid-task and ask "is THIS specific command okay?" This is a
/// request-level gate ("you approve attempting this spoken request at all"),
/// not a per-action confirmation for each individual command Claude might
/// end up running while fulfilling it.
@MainActor
struct ScreenAwarenessActionApproval {
    enum Outcome {
        case approved
        case denied
        /// No biometric/password auth available on this Mac at all.
        case unavailable
    }

    func requestApproval(for question: String) async -> Outcome {
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            return .unavailable
        }
        let reason = "Approve Screen Awareness: \"\(question)\""
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return success ? .approved : .denied
        } catch {
            return .denied
        }
    }
}
