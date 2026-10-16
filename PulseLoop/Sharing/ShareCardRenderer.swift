import SwiftUI
import UIKit
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Renderer

/// Renders `ShareCardView` to a bitmap at `format.scale` (1080×1920 story / 1080×1080 square).
@MainActor
enum ShareCardRenderer {
    static func render(model: ShareCardModel, format: ShareCardFormat) -> UIImage? {
        let renderer = ImageRenderer(
            content: ShareCardView(model: model, format: format)
                .frame(width: format.pointSize.width, height: format.pointSize.height)
                // The card is designed on the app's fixed dark palette; pin the scheme so a
                // future light theme (or system-adaptive colors) can't wash the export out.
                .environment(\.colorScheme, .dark)
        )
        renderer.proposedSize = ProposedViewSize(format.pointSize)
        renderer.scale = format.scale
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// PNG-wrapped render ready for `ShareLink`; nil when rendering or PNG encoding fails.
    static func shareImage(model: ShareCardModel, format: ShareCardFormat, date: Date = Date()) -> ShareCardImage? {
        guard let image = render(model: model, format: format), let data = image.pngData() else { return nil }
        return ShareCardImage(pngData: data, filename: filename(activityLabel: model.activityLabel, date: date))
    }

    /// "pulseloop-{slug}-{yyyy-MM-dd}.png" — slug from the activity label, share date.
    static func filename(activityLabel: String, date: Date = Date()) -> String {
        let slug = activityLabel.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let formatter = DateFormatter.stableKey("yyyy-MM-dd")
        return "pulseloop-\(slug.isEmpty ? "workout" : slug)-\(formatter.string(from: date)).png"
    }

    #if DEBUG
    /// Dev hook for the `-shareCardDump` launch arg: writes both formats to Documents so a
    /// simulator smoke run can pull the exact export bitmaps for visual inspection.
    static func dumpToDocuments(model: ShareCardModel) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        for format in ShareCardFormat.allCases {
            guard let image = render(model: model, format: format), let data = image.pngData() else { continue }
            try? data.write(to: docs.appendingPathComponent("share-card-\(format.rawValue).png"))
        }
    }
    #endif
}

// MARK: - Transferable wrapper

/// The finished PNG as a `ShareLink` item. `nonisolated`: the export closures run off the main
/// actor, and Data/String make the wrapper trivially Sendable.
nonisolated struct ShareCardImage: Transferable {
    let pngData: Data
    let filename: String

    /// Thumbnail for `SharePreview` in the share sheet.
    var previewImage: Image {
        if let uiImage = UIImage(data: pngData) {
            return Image(uiImage: uiImage)
        }
        return Image(systemName: "photo")
    }

    static var transferRepresentation: some TransferRepresentation {
        // File first so receivers (Files, AirDrop, Mail) get the suggested per-workout filename;
        // plain PNG data as the fallback for pasteboard-style receivers.
        FileRepresentation(exportedContentType: .png) { image in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(image.filename)
            try image.pngData.write(to: url)
            return SentTransferredFile(url)
        }
        DataRepresentation(exportedContentType: .png) { $0.pngData }
    }
}
