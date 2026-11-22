import AppKit
import ScreenCaptureKit
import os

/// Single-shot screen capture for the screen-awareness feature. Captures the
/// display under the current key window / mouse (`NSScreen.main`), not always
/// the primary display, so multi-monitor users get the screen they're actually
/// looking at.
@MainActor
final class ScreenAwarenessScreenshotCapturer {
    private let log = Logger.resonant("ScreenAwarenessScreenshotCapturer")

    /// Captures the current display and writes a PNG to a fresh temp file.
    /// The caller owns deletion of the returned URL.
    func captureFrontDisplay() async throws -> URL {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            log.error("Failed to fetch shareable content: \(error, privacy: .public)")
            throw ScreenAwarenessError.screenRecordingPermissionDenied
        }

        guard let display = targetDisplay(in: content.displays) else {
            throw ScreenAwarenessError.screenshotCaptureFailed
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // Native resolution, not retina-supersampled: this only needs to be
        // legible to Claude's Read tool, and halving the pixel count cuts
        // capture/encode/read latency noticeably on the critical path.
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.showsCursor = false

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            log.error("SCScreenshotManager.captureImage failed: \(error, privacy: .public)")
            throw ScreenAwarenessError.screenshotCaptureFailed
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw ScreenAwarenessError.screenshotCaptureFailed
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonant-screen-awareness-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
        } catch {
            log.error("Failed to write screenshot temp file: \(error, privacy: .public)")
            throw ScreenAwarenessError.screenshotCaptureFailed
        }
        return url
    }

    private func targetDisplay(in displays: [SCDisplay]) -> SCDisplay? {
        guard let mainDisplayID = NSScreen.main.flatMap(Self.displayID(for:)) else {
            return displays.first
        }
        return displays.first { $0.displayID == mainDisplayID } ?? displays.first
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
