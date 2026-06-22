import AppKit

struct ScreenshotSaver {
    static func saveCurrentFrame(_ image: NSImage, to directory: URL? = nil) throws -> URL {
        let saveDir = directory ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let filename = "Specchio_\(dateString()).png"
        let fileURL = saveDir.appendingPathComponent(filename)

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Specchio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG data"])
        }

        try pngData.write(to: fileURL)
        return fileURL
    }

    private static func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}
