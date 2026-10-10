import Foundation
import StoicStore
import Synchronization

/// A fresh directory under the system temporary directory, removed when the
/// test is done with it.
struct TempDirectory: ~Copyable {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "stoic-store-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> String { path + "/" + name }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

/// Flips one bit of the byte at `offset` in a file, on disk.
func flipBit(in path: String, at offset: Int, using fs: some FileSystem = PosixFileSystem()) throws {
    let file = try fs.open(path, mode: .readWrite)
    let byte = try fs.read(file, at: offset, count: 1)
    try fs.write(file, [byte[0] ^ 0x10], at: offset)
    try fs.fullSync(file)
    try fs.close(file)
}

/// A value shared between test closures behind a lock.
final class SendableBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) { storage = Mutex(value) }

    var value: Value { storage.withLock { $0 } }

    func mutate(_ body: (inout Value) -> Void) { storage.withLock { body(&$0) } }
}
