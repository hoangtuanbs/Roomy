import Foundation
import RoomyCore
#if canImport(AppKit)
import AppKit
#endif

// roomy-scan [folder] [--top N]       lists the largest items of a folder
// roomy-scan --benchmark <folder>     times a scan and prints the item count and peak memory
// roomy-scan clean [--dry-run] [--yes]
//                                     moves what Smart Clean ticks by itself (caches, logs, build data, package
//                                     caches, old installers) to the Trash after asking; --dry-run only lists it

var args = Array(CommandLine.arguments.dropFirst())

if args.first == "clean" {
    guard let options = CleanCommand.options(Array(args.dropFirst())) else {
        FileHandle.standardError.write(Data("usage: roomy-scan clean [--dry-run] [--yes]\n".utf8))
        exit(2)
    }
    // Caches of apps that are open are left alone, as in the app.
    var running: Set<String> = []
    #if canImport(AppKit)
    running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    #endif
    let home = NSHomeDirectory()
    let service = CleanupService(policy: SafetyPolicy(homePath: home), history: .standard, tool: .commandLine)
    let command = CleanCommand(clean: JunkClean(finder: JunkFinder(homePath: home, skippedCacheNames: running), service: service),
                               dryRun: options.dryRun, assumeYes: options.yes)
    exit(await command.run())
}
var top = 20
if let i = args.firstIndex(of: "--top"), i + 1 < args.count, let n = Int(args[i + 1]) {
    top = n
    args.removeSubrange(i...(i + 1))
}
var benchmark = false
if let i = args.firstIndex(of: "--benchmark") {
    benchmark = true
    args.remove(at: i)
}
let root = args.first ?? NSHomeDirectory()

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("roomy-scan: \(error.localizedDescription)\n".utf8))
    exit(1)
}

/// The most memory the process has used so far, in bytes.
func peakMemory() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    #if os(macOS)
    return Int64(usage.ru_maxrss)
    #else
    return Int64(usage.ru_maxrss) * 1_024
    #endif
}

func timedScan(_ options: ScanOptions) async -> (tree: ScanTree, seconds: Double) {
    let clock = ContinuousClock()
    let start = clock.now
    do {
        let tree = try await DiskScanner(options: options).scan(root: root)
        let elapsed = clock.now - start
        return (tree, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    } catch {
        fail(error)
    }
}

if benchmark {
    let (tree, seconds) = await timedScan(ScanOptions())
    let peak = peakMemory()
    var files = 0, folders = 0, clones = 0, cloudOnly = 0
    for i in 0..<ScanTree.Index(tree.count) {
        if tree.kind(i).isContainer { folders += 1 } else { files += 1 }
        if tree.flags(i).contains(.clone) { clones += 1 }
        if tree.flags(i).contains(.dataless) { cloudOnly += 1 }
    }
    // Both again with the disk cache warm, so the cost of the clone checks shows.
    let (plain, plainSeconds) = await timedScan(ScanOptions(detectClones: false))
    let (_, warmSeconds) = await timedScan(ScanOptions())
    let rate = Double(tree.count) / max(seconds, 0.000_001)
    print("benchmark: \(tree.rootPath)")
    print(String(format: "benchmark: scan %.2f s, %ld items (%ld files, %ld folders), %.0f items/s", seconds, tree.count, files, folders, rate))
    print("benchmark: peak memory \(ByteFormat.string(peak)) (\(peak) bytes)")
    print("benchmark: total \(ByteFormat.string(tree.size(ScanTree.root))), clones \(clones), cloud-only \(cloudOnly)")
    print(String(format: "benchmark: warm cache %.2f s with clone checks, %.2f s without; total without %@ (counting clones once saves %@)",
                 warmSeconds, plainSeconds,
                 ByteFormat.string(plain.size(ScanTree.root)),
                 ByteFormat.string(plain.size(ScanTree.root) - tree.size(ScanTree.root))))
    exit(0)
}

let (tree, seconds) = await timedScan(ScanOptions())
print("\(tree.rootPath): \(ByteFormat.string(tree.size(ScanTree.root))) in \(seconds) s")
for child in tree.children(ScanTree.root).prefix(top) {
    print("\(ByteFormat.string(tree.size(child)))\t\(tree.name(child))")
}
