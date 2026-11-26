// AirDrop receive progress for the island (RE-27-BEHAVIOR s21). 27.3 gets it from sharingd through AirDropUI's Live
// Activity; 26.6 has no AirDropUI, so the incoming items are followed through the NSProgress objects published on
// ~/Downloads (public file-progress API, the one Finder uses for its progress bars).
import Foundation

struct AirDropProgress: Equatable {
    var fraction: Double
    var itemCount: Int
    var isFinished: Bool
}

/// Combined fraction of the files in flight, by bytes. itemCount is transfer sessions in 27.3 (0x10000cb9c), not files;
/// ponytail: [I] 26.6 publishes per file with no session id, so concurrent files count as one session (two senders at
/// once show no count).
func airDropProgress(_ items: [(completed: Int64, total: Int64)]) -> AirDropProgress? {
    guard !items.isEmpty else { return nil }
    let total = items.reduce(0) { $0 + max($1.total, 0) }, done = items.reduce(0) { $0 + max($1.completed, 0) }
    return AirDropProgress(fraction: total > 0 ? min(Double(done) / Double(total), 1) : 0, itemCount: 1, isFinished: false)
}

/// State after the last item is unpublished: finished, or nothing when the transfer was cancelled.
func airDropEnd(cancelled: Bool) -> AirDropProgress? {
    cancelled ? nil : AirDropProgress(fraction: 1, itemCount: 1, isFinished: true)
}

/// ReadyForOpen lines. 27.3 takes both from sharingd's SFAirDrop.PermissionRequest: AIRDROP_RECEIVED_COMPLETED_TEXT
/// "Received %1$@" with the items description, one file as MODERN_TRANSFER '“%1$@”' [? branch not disassembled]
/// (RE-27-BEHAVIOR s21.2.2). 26.6 file progress carries no sender, so "Unknown".
func airDropReadyText(fileName: String?, sender: String?, language: String) -> (title: String, subtitle: String) {
    let vi = language.hasPrefix("vi"), file = fileName.map { "“\($0)”" } ?? "AirDrop"
    let who = sender ?? (vi ? "Không xác định" : "Unknown")
    return (vi ? "Đã nhận \(file)" : "Received \(file)", vi ? "Từ \(who)" : "From \(who)")
}

/// Reports the combined receive progress on the main queue; nil when nothing is being received. Only
/// fileOperationKind .receiving ("receipt of a file from another source"), so browser downloads are ignored.
/// Seen on 26.6: total is 0 at publish, then completedUnitCount climbs to the file size; unpublished when done.
final class AirDropMonitor: @unchecked Sendable {   // state touched on the main queue only
    var onChange: ((AirDropProgress?) -> Void)?
    /// Last file seen (ReadyForOpen title and the Open button).
    private(set) var lastFile: URL?
    private var items: [ObjectIdentifier: (Progress, NSKeyValueObservation)] = [:]
    private var subscriber: Any?

    init?() {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        subscriber = Progress.addSubscriber(forFileURL: downloads) { [weak self] p in
            guard let file = Self.receivedFile(p.userInfo) else { return nil }
            DispatchQueue.main.async { self?.add(p, file) }
            return { DispatchQueue.main.async { self?.remove(p) } }
        }
    }

    /// The received file, or nil for anything else. Measured on 26.6 (AirDrop of sunset.PNG): at publish the proxy's
    /// fileOperationKind and fileURL are still nil; only userInfo holds NSProgressFileOperationKindReceiving and the URL.
    static func receivedFile(_ info: [ProgressUserInfoKey: Any]) -> URL? {
        let kind = (info[.fileOperationKindKey] as? Progress.FileOperationKind)?.rawValue ?? info[.fileOperationKindKey] as? String
        guard kind == Progress.FileOperationKind.receiving.rawValue else { return nil }
        return info[.fileURLKey] as? URL
    }

    deinit { subscriber.map(Progress.removeSubscriber) }

    /// The ring's cancel button (27.3 Button(action: cancel), RE s21.4). Cancelling a subscriber's proxy calls the
    /// publisher's cancellation handler (Finder's progress-bar cancel) [I: sharingd honouring it not seen yet].
    func cancel() { items.values.forEach { $0.0.cancel() } }

    private func add(_ p: Progress, _ file: URL) {
        let o = p.observe(\.completedUnitCount) { [weak self] _, _ in DispatchQueue.main.async { self?.report() } }
        items[ObjectIdentifier(p)] = (p, o)
        lastFile = file
        report()
    }

    private func remove(_ p: Progress) {
        items[ObjectIdentifier(p)] = nil
        if items.isEmpty {   // the last item is in (or was cancelled)
            onChange?(airDropEnd(cancelled: p.isCancelled))
        } else {
            report()
        }
    }

    private func report() {
        onChange?(airDropProgress(items.values.map { (completed: $0.0.completedUnitCount, total: $0.0.totalUnitCount) }))
    }
}
