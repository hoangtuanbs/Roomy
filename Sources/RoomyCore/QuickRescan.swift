import Foundation

/// What a quick rescan did.
public struct QuickRescanReport: Sendable, Equatable {
    /// Folders whose own items were listed again.
    public var listedFolders = 0
    /// Folders scanned again whole: new ones, and ones FSEvents could not say more about.
    public var scannedFolders = 0

    public init(listedFolders: Int = 0, scannedFolders: Int = 0) {
        self.listedFolders = listedFolders
        self.scannedFolders = scannedFolders
    }
}

public enum QuickRescanResult: Sendable, Equatable {
    case patched(QuickRescanReport)
    /// The history cannot be used; the reason is for the log.
    case needsFullScan(String)
}

/// Brings a saved scan up to date by reading only the folders that changed since it was made, as the FSEvents
/// history tells (`ChangeJournal`), and patching them into the tree. Falls back to asking for a full scan when the
/// history is missing, was dropped or coalesced at the top, or the disk is not the same.
public enum QuickRescan {
    public static func run(_ tree: ScanTree, options: ScanOptions = ScanOptions()) async throws -> QuickRescanResult {
        let root = tree.rootPath
        guard tree.journalID > 0 else { return .needsFullScan("the scan has no event id") }
        guard DirectoryReader.entry(atPath: root)?.kind == .directory else { return .needsFullScan("the folder is gone") }
        let volume = ChangeJournal.volumeID(forPath: root)
        guard !volume.isEmpty, volume == tree.volumeID else { return .needsFullScan("the disk is not the same") }
        guard ChangeJournal.currentEventID() >= tree.journalID else { return .needsFullScan("event ids were reset") }

        var aliases: [String] = []
        if let real = realpath(root, nil) {
            aliases.append(String(cString: real))
            free(real)
        }
        guard let history = await ChangeJournal.changes(under: root, since: tree.journalID) else {
            return .needsFullScan("the history could not be read")
        }
        switch ChangeJournal.plan(changes: history.changes, root: root, aliases: aliases) {
        case .full(let reason):
            return .needsFullScan(reason)
        case .upToDate:
            tree.journalID = history.lastID
            return .patched(QuickRescanReport())
        case .patch(let folders, let subtrees):
            let report = try await apply(folders: folders, subtrees: subtrees, to: tree, options: options)
            tree.journalID = history.lastID
            return .patched(report)
        }
    }

    /// Lists `folders` again and scans `subtrees` again whole, and puts what they hold now into `tree`. Totals of
    /// every folder above are kept right; items that are gone are detached, new folders are scanned.
    public static func apply(folders: [String], subtrees: [String], to tree: ScanTree,
                             options: ScanOptions = ScanOptions()) async throws -> QuickRescanReport {
        guard let rootEntry = DirectoryReader.entry(atPath: tree.rootPath) else { throw ScanError.notFound(tree.rootPath) }
        let rules = EntryRules(root: tree.rootPath, rootDevice: rootEntry.device, options: options)
        var report = QuickRescanReport()
        var queue: [String] = []

        for path in subtrees {
            try Task.checkCancellation()
            guard let node = tree.index(ofPath: path), tree.kind(node).isContainer, isOpen(node, in: tree),
                  DirectoryReader.entry(atPath: path)?.kind == .directory else {
                if ChangeJournal.isInside(path, tree.rootPath) { queue.append(parentPath(path)) }
                continue
            }
            guard let fresh = try? await DiskScanner(options: options)
                .scan(root: path, cloneFamilies: tree.cloneFamilies(carriedOutside: node)) else {
                queue.append(parentPath(path))
                continue
            }
            tree.replaceSubtree(node, with: fresh)
            report.scannedFolders += 1
        }

        queue = folders + queue
        var done = Set<String>()
        var touched = Set<ScanTree.Index>()
        while !queue.isEmpty {
            try Task.checkCancellation()
            let path = queue.removeFirst()
            guard done.insert(path).inserted else { continue }
            guard let node = tree.index(ofPath: path) else {
                // Not in the scan: its parent's listing brings it in, if it is there now.
                if ChangeJournal.isInside(path, tree.rootPath) { queue.append(parentPath(path)) }
                continue
            }
            guard tree.kind(node).isContainer else {
                if node != ScanTree.root { queue.append(parentPath(path)) }
                continue
            }
            guard isOpen(node, in: tree) else { continue }
            switch try await relist(node, path: path, in: tree, rules: rules, options: options, report: &report) {
            case .listed: touched.insert(node)
            case .gone: if node != ScanTree.root { queue.append(parentPath(path)) }
            case .unreadable: break
            }
        }

        tree.repairCloneCarriers()
        var resort = Set<ScanTree.Index>()
        for node in touched where !tree.flags(node).contains(.removed) {
            resort.formUnion(tree.lineage(of: node))
        }
        tree.resortChildren(of: resort)
        return report
    }

    private enum Relisted { case listed, gone, unreadable }

    /// Makes the children of `node` match the folder's items now.
    private static func relist(_ node: ScanTree.Index, path: String, in tree: ScanTree, rules: EntryRules,
                               options: ScanOptions, report: inout QuickRescanReport) async throws -> Relisted {
        guard let entries = DirectoryReader.list(path: path, clones: options.detectClones) else {
            if DirectoryReader.entry(atPath: path)?.kind != .directory { return .gone }
            tree.insertFlags(.inaccessible, at: node)
            return .unreadable
        }
        report.listedFolders += 1
        tree.removeFlags(.inaccessible, at: node)
        if let own = DirectoryReader.entry(atPath: path) { tree.setModified(own.modified, at: node) }

        var existing: [String: ScanTree.Index] = [:]
        for child in tree.children(node) { existing[tree.name(child)] = child }
        let listed = Set(existing.values)
        var counter = SpaceCounter(cloneFamilies: tree.cloneFamilies(carriedExcept: { listed.contains($0) }))
        let inCloud = CloudPlaceholder.isInCloudFolder(path)
        let special: NodeFlags = [.dataless, .otherVolume, .excluded]
        var seen = Set<String>()

        for entry in entries {
            seen.insert(entry.name)
            let childPath = DiskScanner.join(path, entry.name)
            let old = existing[entry.name]
            var item: ClassifiedEntry
            if let old, entry.kind != .directory, entry.linkCount > 1, tree.flags(old).contains(.hardLinkDuplicate) {
                // Another link to it carries its size, as in the scan.
                item = ClassifiedEntry(kind: entry.kind, size: 0, flags: [.hardLinkDuplicate], descend: false)
            } else {
                if old != nil { counter.seenInodes.remove(InodeKey(device: entry.device, inode: entry.inode)) }
                item = rules.classify(entry, path: childPath, inCloudFolder: inCloud, counter: &counter)
            }

            if let old {
                let oldKind = tree.kind(old)
                if !oldKind.isContainer && oldKind == item.kind {
                    tree.updateLeaf(old, size: item.size, modified: entry.modified, flags: item.flags)
                    tree.setClone(item.clone, at: old)
                    tree.setOnlineSize(item.onlineBytes, at: old)
                    continue
                }
                if oldKind == item.kind && tree.flags(old).intersection(special) == item.flags.intersection(special) {
                    // A folder that is still a folder: its own changes come with its own events.
                    tree.setModified(entry.modified, at: old)
                    continue
                }
                tree.detach(old)
            }

            let index = tree.insertNode(name: entry.name, parent: node, kind: item.kind, size: item.size,
                                        modified: entry.modified, flags: item.flags)
            tree.setClone(item.clone, at: index)
            tree.setOnlineSize(item.onlineBytes, at: index)
            if item.descend {
                if let fresh = try? await DiskScanner(options: options)
                    .scan(root: childPath, cloneFamilies: tree.cloneFamilies(carriedOutside: index)) {
                    tree.replaceSubtree(index, with: fresh)
                    report.scannedFolders += 1
                } else {
                    tree.detach(index)
                }
            }
        }
        for (name, old) in existing where !seen.contains(name) {
            tree.detach(old)
        }
        return .listed
    }

    /// Folders the scan does not look into (other disks, excluded, cloud-only) stay as they are.
    private static func isOpen(_ node: ScanTree.Index, in tree: ScanTree) -> Bool {
        if node == ScanTree.root { return true }
        return tree.flags(node).intersection([.dataless, .otherVolume, .excluded, .removed]).isEmpty
    }

    private static func parentPath(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}
