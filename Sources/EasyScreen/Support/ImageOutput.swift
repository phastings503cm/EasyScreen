import AppKit
import UniformTypeIdentifiers

/// Encoding, clipboard and file output for captured / edited images.
enum ImageOutput {
    /// Encodes `image`, tagging it with the right DPI (144 on Retina) so it
    /// opens at its on-screen size in other apps.
    static func data(for image: CGImage, scale: CGFloat, format: ImageFormat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        switch format {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .jpeg:
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        }
    }

    static func copyToClipboard(_ image: CGImage, scale: CGFloat, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let item = NSPasteboardItem()
        if let png = rep.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        if let tiff = rep.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.writeObjects([item])
    }

    /// "Screenshot 2026-10-12 at 09.41.07"
    static func baseFilename(prefix: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let cleanPrefix = sanitize(prefix.trimmingCharacters(in: .whitespaces))
        let stamp = formatter.string(from: date)
        return cleanPrefix.isEmpty ? stamp : "\(cleanPrefix) \(stamp)"
    }

    /// Returns a URL in `folder` that doesn't collide with an existing file.
    static func uniqueURL(in folder: URL, baseName: String, fileExtension: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) (\(counter))").appendingPathExtension(fileExtension)
            counter += 1
        }
        return candidate
    }

    /// Writes a new file into `folder`, creating the folder if needed.
    static func save(_ image: CGImage, scale: CGFloat, to folder: URL, prefix: String, date: Date,
                     format: ImageFormat) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, baseName: baseFilename(prefix: prefix, date: date),
                            fileExtension: format.fileExtension)
        try write(image, scale: scale, to: url, format: format)
        return url
    }

    static func write(_ image: CGImage, scale: CGFloat, to url: URL, format: ImageFormat) throws {
        guard let data = data(for: image, scale: scale, format: format) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    static func format(for url: URL) -> ImageFormat {
        ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
    }

    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }
}

enum CaptureSound {
    private static let sound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if FileManager.default.fileExists(atPath: path) {
            return NSSound(contentsOfFile: path, byReference: true)
        }
        return NSSound(named: "Tink")
    }()

    static func play() {
        sound?.stop()
        sound?.play()
    }
}
