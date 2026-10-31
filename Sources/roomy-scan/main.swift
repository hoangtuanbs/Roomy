import Foundation
import RoomyCore

var args = Array(CommandLine.arguments.dropFirst())
var top = 20
if let i = args.firstIndex(of: "--top"), i + 1 < args.count, let n = Int(args[i + 1]) {
    top = n
    args.removeSubrange(i...(i + 1))
}
let root = args.first ?? NSHomeDirectory()
let start = Date()
let tree: ScanTree
do {
    tree = try await DiskScanner().scan(root: root)
} catch {
    FileHandle.standardError.write(Data("roomy-scan: \(error.localizedDescription)\n".utf8))
    exit(1)
}
print("\(tree.rootPath): \(ByteFormat.string(tree.size(ScanTree.root))) in \(Date().timeIntervalSince(start)) s")
for child in tree.children(ScanTree.root).prefix(top) {
    print("\(ByteFormat.string(tree.size(child)))\t\(tree.name(child))")
}
