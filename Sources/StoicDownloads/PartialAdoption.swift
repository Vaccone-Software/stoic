#if STOIC_CRYPTO
internal import Stoic
internal import StoicHTTP
internal import StoicStore

/// What lets a partial file that Stoic did not write be resumed by the
/// server's own word: the validator of the file the bytes came from, as the
/// server last sent it.
///
/// A weak `ETag` (`W/"…"`) is no validator (RFC 9110 forbids `If-Range` to use
/// one), and is treated as none: the adoption then needs a digest to be safe.
public enum PartialValidator: Sendable, Equatable {
    /// A strong entity tag, exactly as the server sent it, quotes included.
    case etag(String)
    /// A `Last-Modified` date, exactly as the server sent it.
    case lastModified(String)

    var validator: Validator? {
        switch self {
        case .etag(let tag):
            let trimmed = tag.trimmingSpaces
            return trimmed.isEmpty || trimmed.hasPrefix("W/") ? nil : Validator(kind: .etag, value: trimmed)
        case .lastModified(let date):
            let trimmed = date.trimmingSpaces
            return trimmed.isEmpty ? nil : Validator(kind: .lastModified, value: trimmed)
        }
    }
}

/// A partial file that an earlier program wrote, and the caller's assurance
/// that it is the first bytes of the file the download names.
///
/// See ``Download/adoptingUnrecordedPartial(at:validator:)``.
public struct PartialAdoption: Sendable, Equatable {
    /// Where the bytes are now.
    public var path: String
    /// What the server will recognise the file by, if the caller kept it.
    public var validator: PartialValidator?

    public init(path: String, validator: PartialValidator? = nil) {
        self.path = path
        self.validator = validator
    }
}

extension String {
    fileprivate var trimmingSpaces: String {
        var scalars = Substring(self)
        while let first = scalars.first, first == " " || first == "\t" { scalars.removeFirst() }
        while let last = scalars.last, last == " " || last == "\t" { scalars.removeLast() }
        return String(scalars)
    }
}

/// Turns a partial file nobody recorded into one the downloader resumes: the
/// resume record it would have written, then the file moved to where it looks.
///
/// The caller's word is *belief*, not proof: all of the file is believed to
/// be the first bytes of the download's file (`synced`), the bytes are made
/// durable first because the record will vouch for them, and the digest,
/// computed over them and the rest, is what says at the end whether the
/// belief was right. Without a digest or a validator there would be nothing
/// to say so, and the file is left alone.
enum Adoption {
    /// Adopts `download.adoption`, if it is offered and there is nothing of
    /// Stoic's to prefer: no partial file at the download's partial path (or
    /// one that has no record, when the adoption *is* that file).
    ///
    /// Crash order: the file's bytes are synced, the record is written
    /// (atomically, durably), and only then is the file renamed. A crash
    /// between the last two leaves a record with no partial file, which the
    /// next run removes, and the file where it was, for the next run to adopt.
    static func adopt(_ download: Download, disk: Disk, label: String) throws(Stop) {
        guard let adoption = download.adoption else { return }
        let partial = download.partialPath
        let fields: [Event.Field] = [.init("request", .string(download.request.description), privacy: .public)]
        let held: Int
        do throws(Stop) {
            if adoption.path == partial {
                guard try disk.exists(partial) else { return }
                // A record of any kind is Stoic's own account of the file.
                guard case .missing = try disk.readRecord(download.resumeRecordPath) else { return }
            } else {
                guard try disk.exists(adoption.path), try !disk.exists(partial) else { return }
            }
            held = try disk.size(ofFileAt: adoption.path) ?? 0
        } catch {
            if case .cancelled = error { throw error }
            decline("unreadable", fields, label)
            return
        }
        let validator = adoption.validator?.validator
        if held == 0 { return decline("empty", fields, label) }
        if let expected = download.expectedSize, held > expected { return decline("larger_than_expected", fields, label) }
        if held > download.byteLimit { return decline("larger_than_limit", fields, label) }
        if validator == nil, download.digest == nil { return decline("nothing_to_resume_by", fields, label) }

        let file = try disk.open(adoption.path, .readWrite)
        var failure: Stop?
        do throws(Stop) {
            try disk.setPermissions(file, to: download.fileMode)
            try disk.fullSync(file)
        } catch {
            failure = error
        }
        try disk.close(file, after: failure)

        let record = ResumeRecord(identity: download.resumeIdentity, validator: validator, synced: held, total: download.expectedSize)
        var durable = try disk.writeRecord(record.encoded(), to: download.resumeRecordPath)
        if adoption.path != partial {
            try disk.rename(from: adoption.path, to: partial)
            do throws(Stop) {
                try disk.syncDirectory(Paths.directory(of: partial))
                if Paths.directory(of: adoption.path) != Paths.directory(of: partial) {
                    try disk.syncDirectory(Paths.directory(of: adoption.path))
                }
            } catch {
                durable = false
            }
        }
        if !durable {
            Ambient.current.instrumentation.record(Event("download.durability_unknown", level: .warning, label: label, fields: fields + [
                .init("what", .string("adoption"), privacy: .public),
            ]))
        }
        Ambient.current.instrumentation.record(Event("download.adopted", level: .info, label: label, fields: fields + [
            .init("bytes", .int(held)),
            .init("validator", .bool(validator != nil)),
        ]))
    }

    private static func decline(_ reason: String, _ fields: [Event.Field], _ label: String) {
        Ambient.current.instrumentation.record(Event("download.adoption_declined", level: .notice, label: label, fields: fields + [
            .init("reason", .string(reason), privacy: .public),
        ]))
    }
}
#endif
