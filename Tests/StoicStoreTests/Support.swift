import Foundation
import StoicStore

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
