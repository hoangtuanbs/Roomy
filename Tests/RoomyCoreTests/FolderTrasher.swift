import Foundation
@testable import RoomyCore

/// Moves items into a folder of the test instead of the real Trash, and records each move.
final class FolderTrasher: Trasher, @unchecked Sendable {
    let folder: String
    private let lock = NSLock()
    private var moves: [String] = []

    init(folder: String) {
        self.folder = folder
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    var moved: [String] { lock.withLock { moves } }

    func moveToTrash(path: String) throws -> String? {
        lock.withLock { moves.append(path) }
        let destination = folder + "/" + UUID().uuidString + "-" + (path as NSString).lastPathComponent
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        return destination
    }
}
