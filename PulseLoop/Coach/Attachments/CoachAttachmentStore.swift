import Foundation
import UIKit

/// A reference to an image attached to a `CoachMessage`. The bytes live on disk in
/// `Documents/coach_attachments/<file>`; the message persists only this small ref
/// (as JSON in `CoachMessage.attachmentsJSON`). Mirrors the `*JSON` ref convention
/// already used for `PendingAction` / `CoachTurnError` — no SwiftData blob, no
/// `@Attribute(.externalStorage)`, so the store stays small and fast.
struct CoachAttachmentRef: Codable, Equatable, Hashable {
    /// Filename within `coach_attachments/` (e.g. `<uuid>.jpg`).
    let file: String
    /// MIME type of the stored bytes (always `image/jpeg` in v1).
    let mime: String
    let width: Int
    let height: Int

    init(file: String, mime: String = "image/jpeg", width: Int, height: Int) {
        self.file = file
        self.mime = mime
        self.width = width
        self.height = height
    }

    /// JSON form for the (array-valued) `CoachMessage.attachmentsJSON` field.
    static func encode(_ refs: [CoachAttachmentRef]) -> String? {
        guard !refs.isEmpty, let data = try? JSONEncoder().encode(refs) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(fromJSON json: String?) -> [CoachAttachmentRef] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CoachAttachmentRef].self, from: data)) ?? []
    }
}

/// The wire-ready forms of one image, built once from a `CoachAttachmentRef`'s
/// bytes and handed to the request builders. Each provider picks the shape it
/// needs: OpenAI/OpenRouter take the `data:` URL; Gemini takes the raw base64 +
/// `mimeType`. Sendable so it can cross the orchestrator's concurrency boundary.
struct CoachImagePayload: Sendable, Equatable {
    /// `data:image/jpeg;base64,<…>` — used by OpenAI `input_image` and OpenRouter `image_url`.
    let dataURL: String
    /// Bare base64 (no `data:` prefix) — used by Gemini `inlineData.data`.
    let rawBase64: String
    let mimeType: String
}

/// On-device store for coach image attachments: compresses + writes incoming
/// images, loads them back for the chat bubble, and produces the base64 payloads
/// the model clients send. Uses `FileManager` + the app Documents directory (the
/// same primitive `DiagnosticsExporter` already relies on).
enum CoachAttachmentStore {
    /// Longest-edge cap applied before JPEG-encoding. Keeps request payloads small
    /// (all three providers bill by image size / cap total request bytes) while
    /// staying sharp enough for the model to read charts and labels.
    private static let maxDimension: CGFloat = 1024
    private static let jpegQuality: CGFloat = 0.7
    static let mimeType = "image/jpeg"

    /// `Documents/coach_attachments/`, created lazily.
    private static func directory() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = docs.appendingPathComponent("coach_attachments", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func url(for ref: CoachAttachmentRef) -> URL? {
        directory()?.appendingPathComponent(ref.file, isDirectory: false)
    }

    // MARK: - Save

    /// Downscales + JPEG-compresses `image`, writes it to a new `<uuid>.jpg`, and
    /// returns the ref. Returns nil if the bytes can't be produced or written.
    static func save(_ image: UIImage) -> CoachAttachmentRef? {
        let scaled = downscaled(image)
        guard let data = scaled.jpegData(compressionQuality: jpegQuality),
              let dir = directory() else { return nil }
        let file = "\(UUID().uuidString).jpg"
        let dest = dir.appendingPathComponent(file, isDirectory: false)
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            return nil
        }
        return CoachAttachmentRef(
            file: file,
            mime: mimeType,
            width: Int(scaled.size.width * scaled.scale),
            height: Int(scaled.size.height * scaled.scale)
        )
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let size = image.size
        let longEdge = max(size.width, size.height)
        guard longEdge > maxDimension else { return image }
        let ratio = maxDimension / longEdge
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: - Load

    static func data(for ref: CoachAttachmentRef) -> Data? {
        guard let url = url(for: ref) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func loadImage(_ ref: CoachAttachmentRef) -> UIImage? {
        guard let data = data(for: ref) else { return nil }
        return UIImage(data: data)
    }

    static func delete(_ ref: CoachAttachmentRef) {
        guard let url = url(for: ref) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Wire payloads

    /// Builds the model-ready payload (data URL + raw base64) for a stored ref.
    static func payload(for ref: CoachAttachmentRef) -> CoachImagePayload? {
        guard let data = data(for: ref) else { return nil }
        let base64 = data.base64EncodedString()
        return CoachImagePayload(
            dataURL: "data:\(ref.mime);base64,\(base64)",
            rawBase64: base64,
            mimeType: ref.mime
        )
    }

    static func payloads(for refs: [CoachAttachmentRef]) -> [CoachImagePayload] {
        refs.compactMap { payload(for: $0) }
    }
}
