import Foundation

struct PasteDiagnosticReport: Identifiable {
    let id = UUID()
    let ranAt: Date
    let deliveryMode: PasteDeliveryMode
    let targetApplicationName: String?
    let targetBundleID: String?
    let accessibilityTrusted: Bool
    let secureInputActive: Bool
    let blockingModifierFlagsRawValue: UInt64
    let deliverySucceeded: Bool
    let insertedIntoTestField: Bool?
    let failure: PasteManager.DeliveryFailure?

    var hasBlockingModifierFlags: Bool {
        blockingModifierFlagsRawValue != 0
    }

    var analyticsProperties: [String: Any] {
        var properties: [String: Any] = [
            "delivery_mode": deliveryMode.rawValue,
            "accessibility_trusted": accessibilityTrusted,
            "secure_input_active": secureInputActive,
            "blocking_modifier_flags": blockingModifierFlagsRawValue,
            "delivery_succeeded": deliverySucceeded,
            "target_bundle_id": targetBundleID as Any,
        ]
        if let insertedIntoTestField {
            properties["inserted_into_test_field"] = insertedIntoTestField
        }
        if let failure {
            properties["failure_type"] = failure.analyticsValue
        }
        return properties
    }

    func withInsertedIntoTestField(_ insertedIntoTestField: Bool) -> PasteDiagnosticReport {
        PasteDiagnosticReport(
            ranAt: ranAt,
            deliveryMode: deliveryMode,
            targetApplicationName: targetApplicationName,
            targetBundleID: targetBundleID,
            accessibilityTrusted: accessibilityTrusted,
            secureInputActive: secureInputActive,
            blockingModifierFlagsRawValue: blockingModifierFlagsRawValue,
            deliverySucceeded: deliverySucceeded,
            insertedIntoTestField: insertedIntoTestField,
            failure: failure
        )
    }
}

extension PasteManager.DeliveryFailure {
    var analyticsValue: String {
        switch self {
        case .accessibilityPermissionRequired:
            return "accessibility_permission_required"
        case .accessibilityPermissionStale:
            return "accessibility_permission_stale"
        case .targetActivationFailed:
            return "target_activation_failed"
        case .noFrontmostTarget:
            return "no_frontmost_target"
        case .deliveryUnverified:
            return "delivery_unverified"
        case .writeFailed:
            return "write_failed"
        case .secureInputActive:
            return "secure_input_active"
        case .partialDelivery:
            return "partial_delivery"
        }
    }
}
