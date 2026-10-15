import Foundation

/// One multipart part: a byte range of the sealed file. `number` is 1-based (S3 / contract `n`).
public struct UploadPart: Equatable, Codable {
    public let number: Int
    public let offset: Int64
    public let length: Int64
    public init(number: Int, offset: Int64, length: Int64) {
        self.number = number; self.offset = offset; self.length = length
    }

    /// Default part size: 8 MiB (S3 minimum is 5 MiB for every part but the last).
    public static let defaultSize: Int64 = 8 * 1024 * 1024
    /// Contract limit for `n`.
    public static let maxParts = 10_000

    /// Splits `totalSize` bytes into consecutive parts of `partSize`; the last part holds the remainder.
    public static func plan(totalSize: Int64, partSize: Int64 = defaultSize) -> [UploadPart] {
        precondition(partSize > 0)
        guard totalSize > 0 else { return [] }
        var parts: [UploadPart] = []
        var offset: Int64 = 0
        var n = 1
        while offset < totalSize {
            let len = min(partSize, totalSize - offset)
            parts.append(UploadPart(number: n, offset: offset, length: len))
            offset += len
            n += 1
        }
        return parts
    }
}

/// Result of one part PUT.
public enum PartUploadOutcome: Equatable {
    case success
    /// Non-2xx HTTP status from object storage (403 = pre-signed URL expired / signature invalid).
    case httpStatus(Int)
    /// Network failure, cancellation, or local I/O failure preparing the part.
    case transportError
}

/// Uploads one part of a file to a pre-signed URL. The app implementation uses a background
/// `URLSession` with `uploadTask(with:fromFile:)` on a temporary part file.
public protocol PartUploader: AnyObject {
    /// PUT bytes `part.offset ..< part.offset + part.length` of `file` to `url`.
    /// `partId` is stable for (artefact, part number) and lets the uploader map background completions back.
    func upload(file: URL, part: UploadPart, to url: URL, partId: String) async -> PartUploadOutcome

    /// The outcome of a task for `partId` started earlier (e.g. by a previous process whose background
    /// transfer finished while the app was not running), awaiting it if still running. nil when no such task.
    func existingOutcome(partId: String) async -> PartUploadOutcome?
}

/// Posts the "needs repeating" notice. The app implementation posts a local notification only when the
/// app is in the background. `text` never contains more than the masked participant code.
public protocol RepeatNotifier: AnyObject {
    func postRepeatNotice(_ text: String)
}
