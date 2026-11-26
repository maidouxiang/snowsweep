import Foundation
import SnowSweepCore

/// 自动空间快照：只读目录体积与磁盘余量，不记录文件名、文件内容，也不执行删除。
/// 触发点有两个：每次扫描成功后立即拍一张；没有扫描时每 7 天补一张。
enum SpaceSnapshotAutoCapture {
    private static let gate = CaptureGate()

    private static var roots: [String] {
        let home = NSHomeDirectory()
        return ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music",
                "Pictures", ".npm", ".gradle"].map { home + "/" + $0 }
    }

    @discardableResult
    static func captureAfterScan(now: Date = Date()) async -> Bool {
        await capture(source: "scan",
                      note: "扫描完成后自动记录",
                      now: now,
                      skipIfRecent: false)
    }

    @discardableResult
    static func captureIfDue(now: Date = Date()) async -> Bool {
        let store = SpaceSnapshotStore()
        let latest = try? await Task.detached(priority: .utility, operation: {
            try store.latest()
        }).value
        guard SpaceSnapshotSchedule.isDue(lastAt: latest?.at, now: now) else { return false }
        return await capture(source: "scheduled",
                             note: "每 7 天自动补记",
                             now: now,
                             skipIfRecent: false)
    }

    private static func capture(
        source: String,
        note: String,
        now: Date,
        skipIfRecent: Bool
    ) async -> Bool {
        guard gate.begin() else { return false }
        defer { gate.end() }

        let store = SpaceSnapshotStore()
        if skipIfRecent,
           let latest = try? await Task.detached(priority: .utility, operation: {
               try store.latest()
           }).value,
           now.timeIntervalSince(latest.at) < 60 {
            return false
        }

        let existingRoots = roots.filter { FileManager.default.fileExists(atPath: $0) }
        let slices = await withTaskGroup(of: VolumeSlice.self) { group -> [VolumeSlice] in
            for path in existingRoots {
                group.addTask {
                    SystemMetrics.directorySize(path, timeout: 45)
                }
            }
            var result: [VolumeSlice] = []
            for await slice in group {
                result.append(slice)
            }
            return result.sorted { $0.bytes > $1.bytes }
        }
        let entries = slices
            .filter { $0.bytes > 0 || $0.isPartial }
            .map {
                SpaceSnapshotEntry(
                    path: ($0.path as NSString).standardizingPath,
                    bytes: max(0, $0.bytes),
                    isPartial: $0.isPartial
                )
            }
        guard !entries.isEmpty else { return false }

        let disk = await Task.detached(priority: .utility) {
            SystemMetrics.disk()
        }.value
        let snapshot = SpaceSnapshot(
            at: now,
            diskTotalBytes: disk.totalBytes,
            diskFreeBytes: disk.freeBytes,
            source: source,
            note: note,
            entries: entries
        )
        do {
            try await Task.detached(priority: .utility) {
                try store.append(snapshot)
            }.value
            return true
        } catch {
            return false
        }
    }
}

/// 扫描收尾和 7 天定时器可能同时触发；同一时间只允许一个目录统计在跑。
private final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if active { return false }
        active = true
        return true
    }

    func end() {
        lock.lock()
        active = false
        lock.unlock()
    }
}
