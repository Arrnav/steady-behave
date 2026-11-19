import AppKit
import AVFoundation
import CoreVideo
import Foundation

/// `Steady --selftest`: checks that don't need the camera. Exits 0 when everything passes.
enum SelfTest {
    private static var failures = 0

    static func run() -> Int32 {
        print("Steady self-test")
        check("Logistic model learns a separable dataset", logisticModel)
        check("Logistic model survives save and load", modelPersistence)
        check("Expression features ignore scale and head roll", featureInvariance)
        check("Expression features react to a wider mouth", featureSensitivity)
        check("Gaze features have 12 values", gazeFeatures)
        check("Clip writer makes a 3 s .mp4", clipWriter)
        check("Clip recorder saves pre- and post-event frames", clipRecorderFlow)
        check("Stats save and reload a day", statsStore)
        check("Clip retention and size cap delete the right files", clipLimits)
        check("Alert cooldown and max 3 repeats", alertRepeats)
        check("Alert cooldown across episodes", alertCooldownAcrossEpisodes)
        check("Look-away alerts after the grace time", lookAwayGrace)
        check("Typing mutes look-away alerts", typingMutes)
        check("Missing face counts as away, then away from desk", missingFace)
        check("Hand near face zone covers the beard", handZone)
        check("Upper-body movement raises the activity score", bodyMovement)
        check("Calm baseline follows quiet periods", calmBaseline)
        check("Settings keep defaults for missing keys", settingsMerge)
        check("Deleting data clears models and stats", deleteData)
        check("Alert colors survive a hex round trip", colorHex)
        check("A detection that is off never alerts", detectionOff)
        check("Detections run only when switched on, not paused and not held by input", detectionGates)
        check("Smoothing reacts at the same speed at any frame rate", smoothingSpeed)
        check("Repeated alerts escalate to blur, then speech", escalationSteps)
        check("Mixed habits escalate together, old alerts expire", escalationMixed)
        check("Tolerance sets the thresholds and the meter counts", escalationTolerance)
        check("Camera turns off when away and back on with input", cameraHoldRules)
        check("Haptics loader reports a backend", haptics)
        print(failures == 0 ? "All checks passed" : "\(failures) check(s) did not pass")
        return failures == 0 ? 0 : 1
    }

    private static func check(_ name: String, _ test: () -> String?) {
        let start = CFAbsoluteTimeGetCurrent()
        let problem = test()
        let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        if let problem {
            failures += 1
            print("FAIL  \(name): \(problem)")
        } else {
            print("PASS  \(name) (\(ms) ms)")
        }
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("steady-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Model

    static func syntheticData() -> (pos: [[Double]], neg: [[Double]]) {
        var rng = SplitMix64(seed: 1)
        func noise() -> Double { Double.random(in: -1...1, using: &rng) }
        var pos: [[Double]] = [], neg: [[Double]] = []
        for _ in 0..<400 {
            pos.append([2 + noise(), 1 + noise() * 0.5, noise(), 5 + noise() * 0.2])
            neg.append([-0.5 + noise(), -1 + noise() * 0.5, noise(), 5 + noise() * 0.2])
        }
        return (pos, neg)
    }

    private static func logisticModel() -> String? {
        let (pos, neg) = syntheticData()
        guard let model = LogisticModel.trainWithValidation(positives: pos, negatives: neg) else { return "training returned nil" }
        let correct = pos.filter { model.probability($0) >= 0.5 }.count + neg.filter { model.probability($0) < 0.5 }.count
        let accuracy = Double(correct) / Double(pos.count + neg.count)
        guard accuracy > 0.95 else { return String(format: "accuracy %.3f", accuracy) }
        guard let held = model.accuracy, held > 0.95 else { return "held-out accuracy \(model.accuracy ?? -1)" }
        return nil
    }

    private static func modelPersistence() -> String? {
        let (pos, neg) = syntheticData()
        guard let model = LogisticModel.train(positives: pos, negatives: neg) else { return "training returned nil" }
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModelStore(url: dir.appendingPathComponent("models.json"))
        store.update { $0.smile = model; $0.smileData.add(positives: pos, negatives: neg) }
        // Saving is asynchronous; wait for the file.
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("models.json").path) {
            usleep(20_000)
        }
        usleep(100_000)
        let reloaded = ModelStore(url: dir.appendingPathComponent("models.json"))
        guard let m2 = reloaded.smile else { return "model missing after reload" }
        for x in pos.prefix(20) + neg.prefix(20) where abs(model.probability(x) - m2.probability(x)) > 1e-9 {
            return "probabilities differ after reload"
        }
        guard reloaded.file.smileData.positives.count == pos.count else { return "training samples not kept" }
        return nil
    }

    // MARK: Features

    /// A plausible synthetic face in image coordinates.
    private static func syntheticFace(mouthWidth: Double = 50) -> Landmarks {
        func ellipse(cx: Double, cy: Double, rx: Double, ry: Double, n: Int) -> [CGPoint] {
            (0..<n).map { i in
                let t = Double(i) / Double(n) * 2 * .pi
                return CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
            }
        }
        var lm: Landmarks = [:]
        lm[.leftEye] = ellipse(cx: -30, cy: 0, rx: 12, ry: 5, n: 8)
        lm[.rightEye] = ellipse(cx: 30, cy: 0, rx: 12, ry: 5, n: 8)
        lm[.leftPupil] = [CGPoint(x: -29, y: 0.5)]
        lm[.rightPupil] = [CGPoint(x: 31, y: 0.5)]
        lm[.leftEyebrow] = (0..<6).map { CGPoint(x: -42 + Double($0) * 5, y: 14 + Double($0 % 3)) }
        lm[.rightEyebrow] = (0..<6).map { CGPoint(x: 18 + Double($0) * 5, y: 14 + Double(($0 + 1) % 3)) }
        lm[.nose] = ellipse(cx: 0, cy: -25, rx: 10, ry: 8, n: 8)
        lm[.outerLips] = ellipse(cx: 0, cy: -55, rx: mouthWidth / 2, ry: 9, n: 14).map { CGPoint(x: $0.x, y: $0.y + ($0.y > -55 ? 1 : 0)) }
        lm[.innerLips] = ellipse(cx: 0, cy: -55, rx: mouthWidth / 2 - 6, ry: 3, n: 8)
        lm[.faceContour] = (0..<11).map { i in
            let t = Double.pi + Double(i) / 10 * .pi
            return CGPoint(x: 70 * cos(t), y: -10 + 80 * sin(t))
        }
        return lm
    }

    private static func transform(_ lm: Landmarks, scale: Double, angle: Double, dx: Double, dy: Double) -> Landmarks {
        lm.mapValues { points in
            points.map { p in
                let x = Double(p.x) * scale, y = Double(p.y) * scale
                return CGPoint(x: x * cos(angle) - y * sin(angle) + dx, y: x * sin(angle) + y * cos(angle) + dy)
            }
        }
    }

    private static func featureInvariance() -> String? {
        let base = syntheticFace()
        guard let f0 = FaceFeatures.smile(base) else { return "no features for base face" }
        for (scale, angle) in [(0.5, 0.0), (1.8, 0.0), (1.0, 0.3), (1.0, -0.35), (2.2, 0.25)] {
            let moved = transform(base, scale: scale, angle: angle, dx: 320, dy: 240)
            guard let f1 = FaceFeatures.smile(moved) else { return "no features after transform" }
            for i in 0..<f0.count {
                let diff = abs(f0[i] - f1[i])
                if diff > 1e-6 * max(1, abs(f0[i])) {
                    return String(format: "%@ changed by %.6f (scale %.1f, roll %.2f)", FaceFeatures.smileNames[i], diff, scale, angle)
                }
            }
        }
        guard f0.count == FaceFeatures.smileCount else { return "expected 11 values, got \(f0.count)" }
        return nil
    }

    private static func featureSensitivity() -> String? {
        guard let narrow = FaceFeatures.smile(syntheticFace(mouthWidth: 50)),
              let wide = FaceFeatures.smile(syntheticFace(mouthWidth: 64)) else { return "no features" }
        guard wide[0] > narrow[0] * 1.2 else { return "mouth width did not grow" }
        guard wide[9] > narrow[9] else { return "mouth / jaw ratio did not grow" }
        return nil
    }

    private static func gazeFeatures() -> String? {
        let lm = syntheticFace()
        guard let g = FaceFeatures.gaze(lm, yaw: 0.1, pitch: -0.05, roll: 0, faceBox: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.4)) else {
            return "no gaze features"
        }
        guard g.count == FaceFeatures.gazeCount else { return "expected 12 values, got \(g.count)" }
        guard abs(g[3] - 1.0 / 24) < 1e-6 else { return String(format: "left pupil x offset %.4f", g[3]) }
        return nil
    }

    // MARK: Clips

    private static func syntheticFrame(_ index: Int, width: Int = ClipRecorder.width, height: Int = ClipRecorder.height) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let rowBytes = CVPixelBufferGetBytesPerRow(pb)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let o = y * rowBytes + x * 4
                    ptr[o] = UInt8((x + index * 8) % 256)
                    ptr[o + 1] = UInt8((y + index * 4) % 256)
                    ptr[o + 2] = UInt8((index * 20) % 256)
                    ptr[o + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    private static func duration(of url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        let result = Locked<Double?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if let d = try? await asset.load(.duration) { result.set(d.seconds) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return result.get()
    }

    private static func clipWriter() -> String? {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.mp4")
        var frames: [(CVPixelBuffer, Double)] = []
        for i in 0..<30 {
            guard let pb = syntheticFrame(i) else { return "could not make a frame" }
            frames.append((pb, Double(i) / 10))
        }
        guard ClipRecorder.write(frames: frames, fps: 10, to: url) else { return "writer reported a problem" }
        guard let d = duration(of: url) else { return "AVAsset could not open the file" }
        guard abs(d - 3.0) < 0.15 else { return String(format: "duration %.2f s", d) }
        return nil
    }

    private static func clipRecorderFlow() -> String? {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = ClipRecorder(root: dir)
        guard let source = syntheticFrame(0, width: 640, height: 480) else { return "could not make a frame" }
        // 12 s of frames at 10 fps, trigger at 10 s, 4 s after.
        var t = 0.0
        while t < 10 {
            recorder.append(source, now: t, meta: ClipFrameMeta(activityScore: 1 + t / 10, handNear: t > 8, smileActive: false))
            t += 0.1
        }
        guard recorder.trigger(.overActive, now: t) else { return "trigger refused" }
        guard !recorder.trigger(.handsAtFace, now: t) else { return "second trigger was accepted while recording" }
        while t < 14.2 { recorder.append(source, now: t, meta: ClipFrameMeta(activityScore: 3, handNear: false, smileActive: false)); t += 0.1 }
        // Writing runs on a background queue; wait for the sidecar.
        var sidecar: URL?
        for _ in 0..<200 {
            let entries = ClipStorage.all(root: dir)
            if let e = entries.first, e.info != nil { sidecar = e.url; break }
            usleep(50_000)
        }
        guard let clip = sidecar, let entry = ClipStorage.all(root: dir).first, let info = entry.info else {
            return "no clip with sidecar was written"
        }
        guard let d = duration(of: clip) else { return "clip could not be opened" }
        guard d > 13, d < 15 else { return String(format: "clip lasts %.1f s, expected about 14", d) }
        guard abs(info.peakActivity - 3) < 0.01 else { return "peak activity \(info.peakActivity)" }
        guard info.handNearPercent > 5, info.handNearPercent < 20 else { return "hand-near-face \(info.handNearPercent)%" }
        guard entry.kind == .overActive else { return "type \(entry.kind)" }
        return nil
    }

    private static func clipLimits() -> String? {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let now = Date()
        func make(_ day: String, _ name: String, ageDays: Double, bytes: Int) -> URL {
            let folder = root.appendingPathComponent(day)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: Data(count: bytes))
            fm.createFile(atPath: url.deletingPathExtension().appendingPathExtension("json").path, contents: Data("{}".utf8))
            try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-ageDays * 86400)], ofItemAtPath: url.path)
            return url
        }
        let old = make("2026-01-01", "10-00-00_overActive.mp4", ageDays: 20, bytes: 1000)
        let a = make("2026-11-10", "10-00-00_smile.mp4", ageDays: 5, bytes: 4000)
        let b = make("2026-11-12", "11-00-00_handsAtFace.mp4", ageDays: 3, bytes: 4000)
        let c = make("2026-11-14", "12-00-00_overActive.mp4", ageDays: 1, bytes: 4000)

        let deleted = ClipStorage.enforceLimits(root: root, retentionDays: 14, capBytes: 9000, now: now)
        let exists = { (u: URL) in fm.fileExists(atPath: u.path) }
        guard !exists(old) else { return "clip older than 14 days was kept" }
        guard !fm.fileExists(atPath: old.deletingLastPathComponent().path) else { return "empty day folder was kept" }
        guard !exists(a) else { return "oldest clip over the cap was kept" }
        guard !exists(a.deletingPathExtension().appendingPathExtension("json")) else { return "sidecar was kept" }
        guard exists(b), exists(c) else { return "a newer clip was deleted" }
        guard deleted.count == 2 else { return "deleted \(deleted.count) files, expected 2" }
        return nil
    }

    // MARK: Stats

    private static func statsStore() -> String? {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stats.json")
        let store = StatsStore(url: url, debounce: 60)
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        store.update(on: day) { d in
            d.smileEpisodes = 14; d.lookAways = 6; d.focusedSeconds = 6000; d.smileSeconds = 31.5; d.missed = 2
        }
        store.update(on: Date()) { $0.overActive = 1 }
        store.saveNow()
        let reloaded = StatsStore(url: url)
        let d = reloaded.day(day)
        guard d == store.day(day) else { return "reloaded day differs" }
        guard d.smileEpisodes == 14, d.lookAways == 6, d.missed == 2 else { return "counters differ" }
        guard reloaded.today.overActive == 1 else { return "today missing" }
        return nil
    }

    // MARK: Alerts

    private static func alertRepeats() -> String? {
        var tracker = EpisodeTracker(hold: 0.6, cooldown: 8, maxAlerts: 3)
        var alerts: [Double] = []
        var ended: [Double] = []
        var t = 0.0
        while t < 40 {
            for e in tracker.update(active: true, value: 0.9, now: t) {
                if case .alert = e { alerts.append(t) }
            }
            t += 1.0 / 15
        }
        guard alerts.count == 3 else { return "expected 3 alerts, got \(alerts.count)" }
        // Each repeat waits the full cooldown, measured at frame steps (1/15 s).
        let gaps = zip(alerts.dropFirst(), alerts).map { $0 - $1 }
        guard abs(alerts[0] - 0.6) < 0.1, gaps.allSatisfy({ $0 >= 8 - 1e-9 && $0 < 8 + 2.0 / 15 }) else {
            return "alert times \(alerts.map { String(format: "%.2f", $0) })"
        }
        while t < 42 {
            for e in tracker.update(active: false, now: t) {
                if case .ended(let d, _, _) = e { ended.append(d) }
            }
            t += 1.0 / 15
        }
        guard ended.count == 1, abs(ended[0] - 40) < 0.2 else { return "episode end \(ended)" }
        // A new episode alerts again.
        var again = 0
        let restart = t
        while t < restart + 1 {
            for e in tracker.update(active: true, now: t) { if case .alert = e { again += 1 } }
            t += 1.0 / 15
        }
        guard again == 1 else { return "new episode gave \(again) alerts" }
        return nil
    }

    private static func alertCooldownAcrossEpisodes() -> String? {
        var tracker = EpisodeTracker(hold: 2, cooldown: 30, maxAlerts: 1, release: 0.5)
        var log: [(Double, EpisodeTracker.Event)] = []
        func run(_ active: Bool, from: Double, to: Double) {
            var t = from
            while t < to {
                for e in tracker.update(active: active, now: t) { log.append((t, e)) }
                t += 0.1
            }
        }
        run(true, from: 0, to: 5)
        run(false, from: 5, to: 7)
        run(true, from: 7, to: 40)
        let alerts = log.filter { if case .alert = $0.1 { return true } else { return false } }.map(\.0)
        let suppressed = log.filter { $0.1 == .suppressedCooldown }.count
        guard alerts.count == 2 else { return "expected 2 alerts, got \(alerts.count)" }
        guard abs(alerts[0] - 2) < 0.15 else { return "first alert at \(alerts[0])" }
        guard abs(alerts[1] - 32) < 0.15 else { return "second alert at \(alerts[1]), expected after the 30 s cooldown" }
        guard suppressed == 1 else { return "cooldown suppression logged \(suppressed) times" }
        return nil
    }
}
