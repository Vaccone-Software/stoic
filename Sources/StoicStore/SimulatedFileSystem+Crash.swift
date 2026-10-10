internal import Synchronization

extension SimulatedFileSystem {
    /// Enumerates the crash images of one frozen state. See
    /// ``SimulatedFileSystem/crashImages(afterOperation:samples:seed:)``.
    struct Explorer {
        let state: State
        let samples: Int
        let seed: UInt64

        /// One way a single file's pending operations can reach the disk.
        struct DataChoice {
            let content: [UInt8]
            let label: String
        }

        func images(at operationCount: Int) -> [CrashImage] {
            let dirOps = state.pendingDirOps
            let dirMasks = Self.masks(count: dirOps.count, seed: seed)
            let pendingInodes = state.inodes.keys.sorted().filter { !state.inodes[$0]!.pending.isEmpty }
            let choices: [Int: [DataChoice]] = Dictionary(uniqueKeysWithValues: pendingInodes.map { ($0, dataChoices(for: $0)) })

            var seen = Set<[String: [UInt8]]>()
            var images: [CrashImage] = []

            func add(dirMask: [Bool], picks: [Int: DataChoice], description: String) {
                let (files, modes) = resolve(dirMask: dirMask, picks: picks)
                guard seen.insert(files).inserted else { return }
                images.append(CrashImage(
                    operationCount: operationCount,
                    description: description,
                    fileSystem: SimulatedFileSystem(restoring: files, modes: modes, like: state)
                ))
            }

            func describe(_ mask: [Bool], _ picks: [Int: DataChoice]) -> String {
                var parts: [String] = []
                if !dirOps.isEmpty {
                    let kept = mask.enumerated().filter(\.element).map { "\($0.offset)" }
                    parts.append("directory ops kept: [\(kept.joined(separator: ","))] of \(dirOps.count)")
                }
                for ino in pendingInodes {
                    if let pick = picks[ino] { parts.append("\(state.inodes[ino]!.name): \(pick.label)") }
                }
                return parts.isEmpty ? "nothing pending" : parts.joined(separator: "; ")
            }

            func uniform(_ keepData: Bool) -> [Int: DataChoice] {
                Dictionary(uniqueKeysWithValues: pendingInodes.map { ino in
                    (ino, keepData ? choices[ino]!.last! : choices[ino]!.first!)
                })
            }

            // Level A: every directory subset, with all pending data kept or none.
            for mask in dirMasks {
                for keep in [false, true] {
                    let picks = uniform(keep)
                    add(dirMask: mask, picks: picks, description: describe(mask, picks) + (keep ? " (all data kept)" : " (no data kept)"))
                }
            }

            // Level B: each file's every outcome, the others at an extreme, the
            // directory entries all kept or all lost.
            let extremes = [Array(repeating: false, count: dirOps.count), Array(repeating: true, count: dirOps.count)]
            for ino in pendingInodes {
                for choice in choices[ino]! {
                    for others in [false, true] {
                        for mask in extremes {
                            var picks = uniform(others)
                            picks[ino] = choice
                            add(dirMask: mask, picks: picks, description: describe(mask, picks))
                        }
                    }
                }
            }

            // Level C: random combinations.
            var random = SplitMix(seed: seed ^ UInt64(truncatingIfNeeded: operationCount) &* 0x9E37_79B9_7F4A_7C15)
            for _ in 0..<samples {
                let mask = dirOps.map { _ in random.next() & 1 == 1 }
                var picks: [Int: DataChoice] = [:]
                for ino in pendingInodes {
                    let options = choices[ino]!
                    picks[ino] = options[Int(random.next() % UInt64(options.count))]
                }
                add(dirMask: mask, picks: picks, description: "random: " + describe(mask, picks))
            }
            return images
        }

        /// The files visible after applying the chosen directory operations
        /// to the durable names and the chosen contents to each file, with
        /// each file's permission bits.
        func resolve(dirMask: [Bool], picks: [Int: DataChoice]) -> (files: [String: [UInt8]], modes: [String: UInt16]) {
            var names = state.durableNames
            for (operation, keep) in zip(state.pendingDirOps, dirMask) where keep {
                operation.apply(to: &names)
            }
            var files: [String: [UInt8]] = [:]
            var modes: [String: UInt16] = [:]
            for (path, ino) in names {
                files[path] = picks[ino]?.content ?? state.inodes[ino]!.durable
                modes[path] = state.inodes[ino]!.mode
            }
            return (files, modes)
        }

        /// Every directory-operation subset when there are few operations;
        /// the prefixes, none and all when there are many.
        static func masks(count: Int, seed: UInt64) -> [[Bool]] {
            if count == 0 { return [[]] }
            if count <= 6 {
                return (0..<(1 << count)).map { bits in (0..<count).map { bits >> $0 & 1 == 1 } }
            }
            return (0...count).map { kept in (0..<count).map { $0 < kept } }
        }

        /// How one file's pending operations can have reached the disk: any
        /// prefix of them, any subset (when there are few), and each write
        /// torn partway. The first choice is "none", the last is "all".
        func dataChoices(for inode: Int) -> [DataChoice] {
            let node = state.inodes[inode]!
            let pending = node.pending
            var choices: [DataChoice] = []
            var seenContent = Set<[UInt8]>()
            func add(_ content: [UInt8], _ label: String) {
                if seenContent.insert(content).inserted { choices.append(DataChoice(content: content, label: label)) }
            }

            // Prefixes, and each write torn after the prefix before it.
            var prefix = node.durable
            add(prefix, "none of \(pending.count) pending ops")
            for (index, operation) in pending.enumerated() {
                if case .write(let offset, let bytes) = operation {
                    for cut in Self.tearPoints(bytes.count) {
                        let torn = Pending.write(offset: offset, bytes: Array(bytes[..<cut]))
                        add(torn.applied(to: prefix), "first \(index) ops, op \(index) torn after \(cut) of \(bytes.count) bytes")
                    }
                }
                prefix = operation.applied(to: prefix)
                add(prefix, index == pending.count - 1 ? "all \(pending.count) ops" : "first \(index + 1) of \(pending.count) ops")
            }

            // Arbitrary subsets, applied in order: the reordering a drive may do.
            if pending.count > 1, pending.count <= 5 {
                for bits in 1..<((1 << pending.count) - 1) {
                    var content = node.durable
                    var kept: [Int] = []
                    for (index, operation) in pending.enumerated() where bits >> index & 1 == 1 {
                        content = operation.applied(to: content)
                        kept.append(index)
                    }
                    add(content, "only ops \(kept) of \(pending.count)")
                }
            }

            // "All" must stay last for the uniform extremes.
            let everything = pending.reduce(node.durable) { $1.applied(to: $0) }
            choices.removeAll { $0.content == everything }
            choices.append(DataChoice(content: everything, label: "all \(pending.count) ops"))
            return choices
        }

        /// The lengths a write of `length` bytes can be cut to: every byte for
        /// short writes, boundaries (sector, power of two, one short) for long.
        static func tearPoints(_ length: Int) -> [Int] {
            guard length > 1 else { return [] }
            if length <= 96 { return Array(1..<length) }
            var points: Set<Int> = [1, length - 1, length / 2]
            var power = 2
            while power < length {
                points.formUnion([power - 1, power, power + 1])
                power *= 2
            }
            var sector = 512
            while sector < length, points.count < 64 {
                points.formUnion([sector - 1, sector, sector + 1])
                sector += 512
            }
            return points.filter { $0 > 0 && $0 < length }.sorted()
        }
    }

    /// A small deterministic generator, so a seed names the same crash images
    /// on every run and every platform.
    struct SplitMix {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A file system holding exactly `files`, all of it durable.
    convenience init(restoring files: [String: [UInt8]], modes: [String: UInt16] = [:], like other: State) {
        self.init(capacity: other.capacity, recordsHistory: other.recordsHistory)
        restore(files, modes: modes, directories: other.directories)
    }

    func restore(_ files: [String: [UInt8]], modes: [String: UInt16] = [:], directories: Set<String>) {
        state.withLock { state in
            state = State(restoring: files, modes: modes, directories: directories, like: state)
        }
    }
}
