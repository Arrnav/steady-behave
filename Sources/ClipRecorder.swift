import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// Per-frame details kept next to each buffered frame, used for the clip's sidecar file.
struct ClipFrameMeta {
    var activityScore = 1.0
    var handNear = false
    var smileActive = false
}

/// The `.json` sidecar saved next to each clip.
struct ClipInfo: Codable {
    var type: AlertKind
    var start: Date
    var duration: Double
    var peakActivity: Double
    var handNearPercent: Double
    var smileEpisodes: Int

    /// A short neutral description, for example "Moving a lot for 9 s (about 3x your calm level)".
    var summary: String {
        let secs = Int(duration.rounded())
        var parts: [String] = []
        switch type {
        case .overActive:
            parts.append(String(format: "Moving a lot for %d s (about %.0fx your calm level)", secs, max(1, peakActivity)))
        case .handsAtFace:
            parts.append("Hands near face for \(secs) s")
        case .smile:
            parts.append("Stretched smile, \(secs) s clip")
        case .lookAway:
            parts.append("Looking away, \(secs) s clip")
        }
        if handNearPercent >= 5, type != .handsAtFace {
            parts.append("hands near face \(Int(handNearPercent.rounded()))% of the time")
        } else if type == .handsAtFace {
            parts.append("\(Int(handNearPercent.rounded()))% of the clip")
        }
        if smileEpisodes > 0, type != .smile {
            parts.append(smileEpisodes == 1 ? "1 smile" : "\(smileEpisodes) smiles")
        }
        return parts.joined(separator: ", ")
    }
}

/// Keeps the last 10 seconds of small frames in memory. On a trigger it records 4 more seconds
/// and writes everything to an H.264 .mp4 on a background queue.
final class ClipRecorder {
    static let width = 480
    static let height = 360
    let fps = 10.0
    let preSeconds = 10.0
    let postSeconds = 4.0

    private struct Frame {
        let buffer: CVPixelBuffer
        let time: Double
        let meta: ClipFrameMeta
    }

    private struct Pending {
        let kind: AlertKind
        let triggerTime: Double
        let pre: [Frame]
        var post: [Frame]
    }

    private var ring: [Frame] = []
    private var pending: Pending?
    private var nextDue = -Double.infinity
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private let writeQueue = DispatchQueue(label: "steady.clips.write", qos: .utility)

    var root: URL
    /// Called on the main thread after a clip is written.
    var onSaved: ((URL, ClipInfo) -> Void)?

    init(root: URL) {
        self.root = root
    }

    var bufferedFrames: Int { ring.count + (pending?.post.count ?? 0) }
    var bufferedBytes: Int { bufferedFrames * Self.width * Self.height * 3 / 2 }
    var isRecording: Bool { pending != nil }

    func clear() {
        ring.removeAll()
        pending = nil
        nextDue = -Double.infinity
    }

    /// Copies the frame into our own small buffer. The camera's buffer is never kept,
    /// because holding it would starve the camera's pool. Call on the camera queue.
    func append(_ source: CVPixelBuffer, now: Double, meta: ClipFrameMeta) {
        // Keep an even 10 fps from a 15 fps source: take a frame each time the next slot is due.
        guard now >= nextDue - 0.005 else {
            finishIfDue(now: now)
            return
        }
        nextDue = max(nextDue + 1 / fps, now - 1 / fps)
        guard let copy = scaledCopy(of: source) else { return }
        let frame = Frame(buffer: copy, time: now, meta: meta)
        ring.append(frame)
        while let first = ring.first, now - first.time > preSeconds { ring.removeFirst() }
        if pending != nil { pending?.post.append(frame) }
        finishIfDue(now: now)
    }

    /// Starts a clip. Returns false if one is already being recorded.
    @discardableResult
    func trigger(_ kind: AlertKind, now: Double) -> Bool {
        guard pending == nil, !ring.isEmpty else { return false }
        pending = Pending(kind: kind, triggerTime: now, pre: ring, post: [])
        return true
    }

    private func finishIfDue(now: Double) {
        guard let p = pending, now - p.triggerTime >= postSeconds else { return }
        pending = nil
        let frames = p.pre + p.post
        guard let first = frames.first, let last = frames.last else { return }

        let startDate = Date().addingTimeInterval(first.time - now)
        let duration = last.time - first.time + 1 / fps
        var smileEpisodes = 0
        var wasSmiling = false
        for f in frames {
            if f.meta.smileActive && !wasSmiling { smileEpisodes += 1 }
            wasSmiling = f.meta.smileActive
        }
        let info = ClipInfo(
            type: p.kind, start: startDate, duration: duration,
            peakActivity: frames.map(\.meta.activityScore).max() ?? 1,
            handNearPercent: 100 * Double(frames.filter { $0.meta.handNear }.count) / Double(frames.count),
            smileEpisodes: smileEpisodes)
        let url = ClipStorage.newClipURL(root: root, date: startDate, kind: p.kind)
        let timed = frames.map { ($0.buffer, $0.time) }
        writeQueue.async { [weak self] in
            let ok = Self.write(frames: timed, fps: self?.fps ?? 10, to: url)
            guard ok else {
                EventLog.shared.add(.info, p.kind, "Clip could not be saved")
                return
            }
            if let data = try? Self.encoder.encode(info) {
                try? data.write(to: url.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
            }
            DispatchQueue.main.async { self?.onSaved?(url, info) }
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func scaledCopy(of source: CVPixelBuffer) -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [String: Any] = [
                // YUV 4:2:0 uses 1.5 bytes per pixel instead of 4, so the 14 s buffer stays near 26 MB.
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: Self.width,
                kCVPixelBufferHeightKey as String: Self.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }
        let sw = CGFloat(CVPixelBufferGetWidth(source)), sh = CGFloat(CVPixelBufferGetHeight(source))
        let scale = min(CGFloat(Self.width) / sw, CGFloat(Self.height) / sh)
        let dx = (CGFloat(Self.width) - sw * scale) / 2, dy = (CGFloat(Self.height) - sh * scale) / 2
        let image = CIImage(cvPixelBuffer: source)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: dx, y: dy)))
        ciContext.render(image, to: out)
        return out
    }

    /// Writes frames to an H.264 .mp4. Blocks until done. Safe on any background queue.
    static func write(frames: [(CVPixelBuffer, Double)], fps: Double, to url: URL) -> Bool {
        guard let first = frames.first, let last = frames.last else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let w = CVPixelBufferGetWidth(first.0), h = CVPixelBufferGetHeight(first.0)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 700_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(first.0),
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let t0 = first.1
        var lastPTS = CMTime.zero
        for (buffer, t) in frames {
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 400 {
                usleep(5000); waited += 1
            }
            var pts = CMTime(seconds: t - t0, preferredTimescale: 600)
            if pts <= lastPTS && pts != .zero { pts = lastPTS + CMTime(value: 1, timescale: 600) }
            if !adaptor.append(buffer, withPresentationTime: pts) { break }
            lastPTS = pts
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: last.1 - t0 + 1 / fps, preferredTimescale: 600))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }
}

/// Where clips live and how storage limits are kept.
enum ClipStorage {
    struct Entry: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let day: String
        let date: Date
        let kind: AlertKind
        let bytes: Int
        let info: ClipInfo?

        static func == (a: Entry, b: Entry) -> Bool { a.url == b.url }
        func hash(into hasher: inout Hasher) { hasher.combine(url) }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH-mm-ss"
        return f
    }()

    static func newClipURL(root: URL, date: Date, kind: AlertKind) -> URL {
        root.appendingPathComponent(dayFormatter.string(from: date), isDirectory: true)
            .appendingPathComponent("\(timeFormatter.string(from: date))_\(kind.rawValue).mp4")
    }

    static func clipCount(root: URL, on date: Date) -> Int {
        let folder = root.appendingPathComponent(dayFormatter.string(from: date), isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasSuffix(".mp4") }.count
    }

    /// All clips, newest first.
    static func all(root: URL) -> [Entry] {
        let fm = FileManager.default
        var out: [Entry] = []
        let days = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for day in days where dayFormatter.date(from: day) != nil {
            let folder = root.appendingPathComponent(day, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".mp4") {
                let url = folder.appendingPathComponent(name)
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                let modified = attrs?[.modificationDate] as? Date ?? Date.distantPast
                let sidecar = url.deletingPathExtension().appendingPathExtension("json")
                let info = (try? Data(contentsOf: sidecar)).flatMap { try? ClipRecorder.decoder.decode(ClipInfo.self, from: $0) }
                let kindRaw = name.replacingOccurrences(of: ".mp4", with: "").split(separator: "_").last.map(String.init) ?? ""
                let kind = info?.type ?? AlertKind(rawValue: kindRaw) ?? .overActive
                out.append(Entry(url: url, day: day, date: info?.start ?? modified, kind: kind, bytes: bytes, info: info))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    static func totalBytes(root: URL) -> Int {
        all(root: root).reduce(0) { $0 + $1.bytes }
    }

    /// Removes a clip and its sidecar right away (used for automatic limits).
    static func remove(_ url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
        let folder = url.deletingLastPathComponent()
        if let rest = try? fm.contentsOfDirectory(atPath: folder.path), rest.filter({ !$0.hasPrefix(".") }).isEmpty {
            try? fm.removeItem(at: folder)
        }
    }

    /// Deletes clips older than the retention period, then the oldest clips until under the size cap.
    /// Returns the deleted clip URLs.
    @discardableResult
    static func enforceLimits(root: URL, retentionDays: Int, capBytes: Int, now: Date = Date()) -> [URL] {
        var deleted: [URL] = []
        let fm = FileManager.default
        var entries: [(url: URL, modified: Date, bytes: Int)] = []
        let days = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for day in days {
            let folder = root.appendingPathComponent(day, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".mp4") {
                let url = folder.appendingPathComponent(name)
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let modified = attrs?[.modificationDate] as? Date ?? now
                var bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                let sidecar = url.deletingPathExtension().appendingPathExtension("json")
                bytes += ((try? fm.attributesOfItem(atPath: sidecar.path))?[.size] as? NSNumber)?.intValue ?? 0
                entries.append((url, modified, bytes))
            }
        }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        for e in entries where e.modified < cutoff {
            remove(e.url); deleted.append(e.url)
        }
        var remaining = entries.filter { $0.modified >= cutoff }.sorted { $0.modified < $1.modified }
        var total = remaining.reduce(0) { $0 + $1.bytes }
        while total > capBytes, !remaining.isEmpty {
            let oldest = remaining.removeFirst()
            remove(oldest.url); deleted.append(oldest.url)
            total -= oldest.bytes
        }
        return deleted
    }
}
