import CryptoKit
import Foundation
import Sentry

/// Event-scoped replayable MSL: Sentry truncates extra/context strings to 16 KiB.
/// Only complete numbered captures are attachments; excerpts remain diagnostics.
struct FailedShaderAttachments {
    static let sourceLimit = 256 * 1024
    static let recordLimit = 384 * 1024  // Source plus up to 8192 numbered line prefixes.
    static let extraLimit = 16 * 1024
    private var sent: Set<String> = []

    mutating func claim(extra: [String: String], scrub: (String) -> String) -> [Attachment] {
        guard sent.count < 2 else { return [] }
        var records = extra.keys.filter { $0.hasPrefix("msl_stage_") }.sorted().compactMap { extra[$0] }
        if let header = extra["msl_source"], let source = extra["msl_error_context"] {
            records.append(header + "\n" + source)
        }
        var attachments: [Attachment] = []
        for record in records {
            guard sent.count < 2 else { break }
            guard let source = Self.source(from: record) else { continue }
            let data = Data(scrub(source).utf8)
            guard !data.isEmpty, data.count <= Self.sourceLimit else { continue }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard sent.insert(hash).inserted else { continue }
            attachments.append(Attachment(data: data, filename: "shader-\(hash).metal", contentType: "text/plain"))
        }
        return attachments
    }

    private static func source(from record: String) -> String? {
        let lines = record.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("// Pipeline failure MSL ") || $0.hasPrefix("// Library failure MSL ")
        }) else { return nil }
        let fields = lines[start].split(separator: " ")
        func number(_ name: String) -> Int? {
            fields.first(where: { $0.hasPrefix(name + "=") }).flatMap { Int($0.dropFirst(name.count + 1)) }
        }
        guard fields.contains("capture=full"), let bytes = number("bytes"), let count = number("lines"),
              bytes > 0, bytes <= sourceLimit, count > 0, count <= 8192,
              lines.count - start - 1 >= count else { return nil }
        var source = ""
        source.reserveCapacity(bytes + 1)
        for index in 0..<count {
            let line = lines[start + 1 + index]
            guard let colon = line.range(of: ": "), Int(line[..<colon.lowerBound]) == index + 1 else { return nil }
            source += line[colon.upperBound...]
            source += "\n"
        }
        // The logger also appends a newline when the original last line had none.
        if source.utf8.count == bytes + 1 { source.removeLast() }
        guard source.utf8.count == bytes else { return nil }
        return source
    }
}
