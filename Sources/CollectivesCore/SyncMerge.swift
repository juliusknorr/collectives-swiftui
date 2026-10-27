import Foundation

public extension AccountSnapshot {
    /// Applies a sync checkpoint while preserving work performed since the previous checkpoint.
    /// Use the initial snapshot for the first baseline, then the previous unmerged checkpoint.
    func mergingSync(_ remote: AccountSnapshot, startedFrom base: AccountSnapshot) -> AccountSnapshot {
        var merged = remote
        merged.collectives = mergeSyncItems(remote.collectives, local: collectives, base: base.collectives)
        for key in Set(remote.pages.keys).union(pages.keys).union(base.pages.keys) {
            let items = mergeSyncItems(remote.pages[key] ?? [], local: pages[key] ?? [], base: base.pages[key] ?? [])
            merged.pages[key] = items.isEmpty ? nil : items
        }

        for (key, local) in documents {
            let original = base.documents[key]
            let contentChanged = original.map { !sameSyncContent(local, $0) } ?? true
            let metadataChanged = original.map { local.page != $0.page || local.collectiveID != $0.collectiveID } ?? true
            guard contentChanged || metadataChanged else { continue }

            guard var synced = remote.documents[key] else {
                merged.documents[key] = local
                continue
            }
            if contentChanged && (original != nil || local.hasLocalChanges) {
                if local.conflict != original?.conflict {
                    synced.markdown = local.markdown
                    synced.etag = local.etag
                    synced.draft = local.draft
                    synced.conflict = local.conflict
                } else {
                    let latestText = local.draft ?? local.markdown
                    if synced.conflict == nil,
                       synced.markdown != (original?.markdown ?? local.markdown),
                       synced.markdown != original?.draft,
                       latestText != synced.markdown {
                        synced.conflict = RemoteDocument(markdown: synced.markdown, etag: synced.etag)
                        synced.markdown = local.markdown
                        synced.etag = local.etag
                        synced.draft = latestText
                    } else {
                        synced.draft = latestText == synced.markdown ? nil : latestText
                    }
                }
            }
            if metadataChanged {
                synced.page = local.page
                synced.collectiveID = local.collectiveID
            }
            merged.documents[key] = synced
        }

        // A server deletion must not hide work created or edited while syncing.
        for (key, document) in merged.documents where remote.documents[key] == nil {
            let collectiveKey = String(document.collectiveID)
            if !merged.collectives.contains(where: { $0.id == document.collectiveID }),
               let collective = collectives.first(where: { $0.id == document.collectiveID }) {
                merged.collectives.append(collective)
            }
            var listing = merged.pages[collectiveKey] ?? []
            var page: Page? = document.page
            var visited = Set<Int>()
            while let current = page, visited.insert(current.id).inserted {
                if !listing.contains(where: { $0.id == current.id }) { listing.append(current) }
                page = pages[collectiveKey]?.first(where: { $0.id == current.parentId })
            }
            merged.pages[collectiveKey] = listing
        }
        return merged
    }
}

private func sameSyncContent(_ lhs: CachedDocument, _ rhs: CachedDocument) -> Bool {
    lhs.markdown == rhs.markdown && lhs.etag == rhs.etag && lhs.draft == rhs.draft && lhs.conflict == rhs.conflict
}

private func mergeSyncItems<Item: Identifiable & Equatable>(
    _ remote: [Item], local: [Item], base: [Item]
) -> [Item] {
    let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    let remoteIDs = Set(remote.map(\.id))
    return remote.compactMap { item in
        if let localItem = localByID[item.id], localItem != baseByID[item.id] { return localItem }
        if baseByID[item.id] != nil && localByID[item.id] == nil { return nil }
        return item
    } + local.filter { !remoteIDs.contains($0.id) && $0 != baseByID[$0.id] }
}
