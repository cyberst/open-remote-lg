import Foundation

/// Parsing of HTTP `Range: bytes=…` headers (RFC 9110 §14) for a resource of a known size.
enum ByteRangeRequest: Equatable {
    /// No (usable) Range header: send the whole resource with 200.
    case full
    /// Send these bytes with 206.
    case partial(ClosedRange<Int64>)
    /// Range cannot be satisfied: respond 416 with `Content-Range: bytes */size`.
    case unsatisfiable

    /// Only the first range of a multi-range request is honoured (TVs never ask for more than one in practice);
    /// syntactically invalid headers are ignored, as the RFC requires.
    static func parse(_ header: String?, size: Int64) -> ByteRangeRequest {
        guard let header else { return .full }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = trimmed.dropFirst("bytes=".count)
        guard let first = spec.split(separator: ",", omittingEmptySubsequences: true).first else { return .full }
        let parts = first.trimmingCharacters(in: .whitespaces).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .full }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endText = parts[1].trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            // Suffix range: last N bytes.
            guard let suffix = Int64(endText), suffix >= 0 else { return .full }
            guard suffix > 0, size > 0 else { return .unsatisfiable }
            return .partial(max(0, size - suffix)...(size - 1))
        }
        guard let start = Int64(startText), start >= 0 else { return .full }
        let end: Int64
        if endText.isEmpty {
            end = size - 1
        } else {
            guard let e = Int64(endText) else { return .full }
            guard e >= start else { return .full }
            end = min(e, size - 1)
        }
        guard start < size else { return .unsatisfiable }
        return .partial(start...end)
    }
}
