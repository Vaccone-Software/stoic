#if STOIC_CRYPTO
internal import Stoic
internal import StoicHTTP
internal import StoicStore

/// A bundle, from the first file to the directory in place.
///
/// The staging directory is the whole of the state that outlives the process:
/// every file in it is either complete (at its own name), part-way (at
/// `<name>.partial`, with its record), or absent, and a run starts by
/// finding out which. Placing is one `replaceItem`.
struct BundleTransfer {
    let bundle: DownloadBundle
    let client: HTTPClient
    let disk: Disk
    let policy: DownloadPolicy
    let label: String
    let progress: ProgressReporter

    func run() async throws(Stop) -> DownloadBundleResult {
        do throws(Stop) {
            try disk.createDirectory(Paths.directory(of: bundle.destination))
            try disk.createDirectory(bundle.stagingPath)
            try removeStrays()
            try preflightSpace()

            let total = bundle.files.allSatisfy { $0.expectedSize != nil } ? bundle.files.reduce(0) { $0 + ($1.expectedSize ?? 0) } : nil
            var results: [DownloadResult] = []
            var bytesBefore = 0
            for (index, file) in bundle.files.enumerated() {
                progress.beginFile(index: index, of: bundle.files.count, bytesBefore: bytesBefore, totalBytes: total)
                let target = Paths.join(bundle.stagingPath, file.path)
                if file.path.contains("/") { try disk.createDirectory(Paths.directory(of: target)) }
                let download = Download(
                    file.request, to: target, expectedSize: file.expectedSize, digest: file.digest, byteLimit: file.byteLimit,
                    keepsPartialOnCancel: bundle.keepsPartialOnCancel, fileMode: bundle.fileMode)
                if file.adoptsUnrecordedPartial {
                    // Before `reuse`, which removes what is at the file's own name and is not whole.
                    try Adoption.adopt(
                        download.adoptingUnrecordedPartial(at: target, validator: file.adoptedValidator), disk: disk, label: label)
                }
                let result: DownloadResult
                if let reused = try await reuse(file, at: target) {
                    result = reused
                } else {
                    result = try await FileTransfer(download, client: client, disk: disk, policy: policy, label: label, progress: progress).run()
                }
                results.append(result)
                bytesBefore += result.bytes
            }
            // Everything is in; what is left is the swap, which is the whole of the bundle's progress.
            progress.beginFile(index: bundle.files.count - 1, of: bundle.files.count, bytesBefore: bytesBefore, totalBytes: total)
            let durable = try place()
            record(Event("download.placed", level: .info, label: label, fields: [
                .init("files", .int(results.count)),
                .init("bytes", .int(bytesBefore)),
                .init("durable", .bool(durable)),
            ]))
            return DownloadBundleResult(
                path: bundle.destination,
                files: zip(results, bundle.files).map { result, file in
                    var placed = result
                    placed.path = Paths.join(bundle.destination, file.path)
                    return placed
                },
                isDurable: durable)
        } catch {
            if case .cancelled = error, !bundle.keepsPartialOnCancel { removeStagingQuietly() }
            throw error
        }
    }

    private func record(_ event: Event) {
        Ambient.current.instrumentation.record(event)
    }

    // MARK: Staging

    /// Everything the staging directory may hold: each file at its own name,
    /// its partial and that partial's record, and the directories that lead
    /// to them.
    private var expected: (names: Set<String>, directories: Set<String>) {
        var names: Set<String> = []
        var directories: Set<String> = []
        for file in bundle.files {
            names.insert(file.path)
            names.insert(file.path + ".partial")
            names.insert(file.path + ".partial.resume")
            var parent = Paths.directory(of: file.path)
            while parent != "." {
                directories.insert(parent)
                parent = Paths.directory(of: parent)
            }
        }
        return (names, directories)
    }

    /// Removes what is in the staging directory and is not the bundle's: the
    /// files of an earlier version of it, or of one that has changed since.
    private func removeStrays() throws(Stop) {
        let (names, directories) = expected
        var removed = 0
        func sweep(_ directory: String, _ relative: String) throws(Stop) {
            guard let entries = try disk.entries(of: directory) else { return }
            for name in entries {
                let path = Paths.join(directory, name)
                let key = relative.isEmpty ? name : relative + "/" + name
                if names.contains(key) { continue }
                if directories.contains(key) {
                    try sweep(path, key)
                } else {
                    try disk.removeIfPresent(path)
                    removed += 1
                }
            }
        }
        try sweep(bundle.stagingPath, "")
        if removed > 0 {
            record(Event("download.restarted", level: .notice, label: label, fields: [
                .init("reason", .string("stale_staging_files"), privacy: .public),
                .init("removed", .int(removed)),
            ]))
        }
    }

    /// A file that is already whole in the staging directory, at its expected
    /// size and with a digest that checks, is verified and not fetched again.
    /// Anything else at its name is not what this download left there (it
    /// could not be told from a file of an older version) and is removed.
    private func reuse(_ file: DownloadBundle.File, at target: String) async throws(Stop) -> DownloadResult? {
        guard try disk.exists(target) else { return nil }
        guard let size = file.expectedSize, let digest = file.digest else {
            try removeStaged(file, at: target, reason: "staged_file_unverifiable")
            return nil
        }
        guard try disk.size(ofFileAt: target) == size else {
            try removeStaged(file, at: target, reason: "staged_file_wrong_size")
            return nil
        }
        let handle = try disk.open(target, .read)
        var hasher = ContentHasher(digest.algorithm, size: size)
        var whole = false
        var failure: Stop?
        do throws(Stop) {
            whole = try await disk.hash(handle, count: size, into: &hasher) { hashed in
                progress.report(.verifying, fileBytes: hashed, fileTotal: size)
            }
        } catch {
            failure = error
        }
        try disk.close(handle, after: failure)
        guard whole, hasher.hex == digest.hex else {
            try removeStaged(file, at: target, reason: "staged_file_failed_verification")
            return nil
        }
        record(Event("download.file_reused", level: .info, label: label, fields: [
            .init("request", .string(file.request.description), privacy: .public),
            .init("bytes", .int(size)),
        ]))
        return DownloadResult(path: target, bytes: size, verifiedDigest: digest, resumedFrom: size, requests: 0, isDurable: true)
    }

    private func removeStaged(_ file: DownloadBundle.File, at target: String, reason: String) throws(Stop) {
        try disk.removeIfPresent(target)
        record(Event("download.restarted", level: .notice, label: label, fields: [
            .init("request", .string(file.request.description), privacy: .public),
            .init("reason", .string(reason), privacy: .public),
        ]))
    }

    private func preflightSpace() throws(Stop) {
        let required: UInt64
        if let explicit = bundle.requiredFreeBytes {
            required = explicit
        } else {
            var remaining = 0
            for file in bundle.files {
                guard let size = file.expectedSize else { continue }
                // What is already on disk for a file (whole, or part-way) is already allocated.
                let held = try heldBytes(of: file)
                remaining += max(0, size - held)
            }
            guard remaining > 0 else { return }
            required = UInt64(remaining) + policy.freeSpaceMargin
        }
        guard required > 0, let available = disk.freeSpace(at: bundle.stagingPath) else { return }
        guard available >= required else { throw Stop(.insufficientSpace(required: required, available: available)) }
    }

    /// The size of what the staging directory holds for `file`: the file, or
    /// its partial.
    private func heldBytes(of file: DownloadBundle.File) throws(Stop) -> Int {
        let target = Paths.join(bundle.stagingPath, file.path)
        if let size = try disk.size(ofFileAt: target) { return size }
        return try disk.size(ofFileAt: target + ".partial") ?? 0
    }

    // MARK: Placing

    /// Swaps the staging directory over the destination (`AtomicFile.replaceItem`):
    /// the old directory, if there is one, is the staging path's afterwards and
    /// is removed. A failure of the sync after the swap leaves the new
    /// directory in place; it is reported, not thrown, as for a single file,
    /// and the old directory, which `AtomicFile` leaves at the staging path
    /// when it cannot say the swap is durable, is removed.
    private func place() throws(Stop) -> Bool {
        progress.report(.placing, fileBytes: 0, fileTotal: nil)
        let durable = try disk.replaceItem(at: bundle.destination, withItemAt: bundle.stagingPath)
        if !durable {
            record(Event("download.durability_unknown", level: .warning, label: label, fields: [
                .init("what", .string("bundle"), privacy: .public),
            ]))
            // The swap happened, so what the staging path holds now is the old directory (nothing, if
            // there was none): it is not this download's to keep, and the next run would only sweep
            // it as strays. `AtomicFile` leaves it for us exactly because it did not finish its own
            // cleanup.
            removeStagingQuietly()
        }
        return durable
    }

    private func removeStagingQuietly() {
        do throws(Stop) {
            try disk.removeIfPresent(bundle.stagingPath)
        } catch {
            record(Event("download.cleanup_failed", level: .warning, label: label, fields: [
                .init("what", .string("staging"), privacy: .public),
            ]))
        }
    }
}
#endif
