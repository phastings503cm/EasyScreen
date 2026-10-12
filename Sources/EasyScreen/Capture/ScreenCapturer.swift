import AppKit
import ImageIO
import ScreenCaptureKit

/// A frozen snapshot of one display, taken before the selection overlay appears.
struct DisplaySnapshot {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    /// Full-resolution image of the display (pixels).
    let image: CGImage
    /// Pixels per point for `image` relative to `screen.frame`.
    var scale: CGFloat { CGFloat(image.width) / max(screen.frame.width, 1) }
}

/// A capture result ready for the after-capture actions.
struct CapturedImage {
    let image: CGImage
    /// Pixels per point (2 on Retina displays) so outputs keep the right DPI.
    let scale: CGFloat
    let date: Date

    var pointSize: NSSize {
        NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    /// Loads an image file, honouring its DPI (a 144-dpi PNG opens at 2x).
    static func load(from url: URL) -> CapturedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var scale: CGFloat = 1
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 72 {
            scale = max(1, (CGFloat(dpi) / 72).rounded())
        }
        let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        return CapturedImage(image: image, scale: scale, date: date)
    }
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplays
    case failed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen Recording permission is required."
        case .noDisplays: return "No displays are available to capture."
        case .failed(let error): return error.localizedDescription
        }
    }
}

enum ScreenCapturer {
    /// Captures every connected display concurrently at native resolution.
    @MainActor
    static func snapshotAllDisplays() async throws -> [DisplaySnapshot] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw CaptureError.noDisplays }
        // Check first: ScreenCaptureKit raises its own system prompt when
        // refused, which would stack with EasyScreen's guidance.
        guard Permissions.hasScreenRecording else { throw CaptureError.permissionDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw CaptureError.permissionDenied }
            throw CaptureError.failed(error)
        }

        var jobs: [(index: Int, display: SCDisplay, scale: CGFloat)] = []
        for (index, screen) in screens.enumerated() {
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id })
            else { continue }
            jobs.append((index, display, screen.backingScaleFactor))
        }
        guard !jobs.isEmpty else { throw CaptureError.noDisplays }

        let images: [Int: CGImage]
        do {
            images = try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
                for job in jobs {
                    let display = job.display
                    let scale = job.scale
                    let index = job.index
                    group.addTask {
                        let filter = SCContentFilter(display: display, excludingWindows: [])
                        let config = SCStreamConfiguration()
                        let pixelScale = CGFloat(filter.pointPixelScale) > 0 ? CGFloat(filter.pointPixelScale) : scale
                        config.width = Int((filter.contentRect.width * pixelScale).rounded())
                        config.height = Int((filter.contentRect.height * pixelScale).rounded())
                        config.showsCursor = false
                        config.captureResolution = .best
                        config.ignoreShadowsDisplay = false
                        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        return (index, image)
                    }
                }
                var result: [Int: CGImage] = [:]
                for try await (index, image) in group {
                    result[index] = image
                }
                return result
            }
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw CaptureError.permissionDenied }
            throw CaptureError.failed(error)
        }

        return jobs.compactMap { job in
            guard let image = images[job.index] else { return nil }
            return DisplaySnapshot(screen: screens[job.index], displayID: job.display.displayID, image: image)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// This screen's frame in CoreGraphics global coordinates (origin at the
    /// top-left of the primary display, y pointing down).
    var cgFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

/// On-screen windows (front to back) used to let a click select a whole window.
struct OnScreenWindow {
    /// Frame in CoreGraphics global coordinates.
    let frame: CGRect
    let ownerName: String

    static func current() -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return info.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 40, bounds.height >= 40
            else { return nil }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha < 0.05 { return nil }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            return OnScreenWindow(frame: bounds, ownerName: owner)
        }
    }
}
