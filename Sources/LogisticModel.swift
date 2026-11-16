import Foundation

/// Small deterministic random number generator, so training gives the same result every time.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// A tiny personal classifier: standardize, expand each feature to [x, x^2],
/// then binary logistic regression trained with mini-batch gradient descent.
struct LogisticModel: Codable {
    var mean: [Double]
    var std: [Double]
    var weights: [Double]
    var bias: Double
    /// Accuracy on a held-out 20% split, measured when the model was trained.
    var accuracy: Double?
    var positives = 0
    var negatives = 0
    var trainedAt = Date()

    var inputCount: Int { mean.count }

    func expand(_ x: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: x.count * 2)
        for i in 0..<x.count {
            // Clamp z-scores so a single odd frame can't dominate.
            let z = max(-6, min(6, (x[i] - mean[i]) / std[i]))
            out[i * 2] = z
            out[i * 2 + 1] = z * z
        }
        return out
    }

    func probability(_ x: [Double]) -> Double {
        guard x.count == mean.count else { return 0 }
        let e = expand(x)
        var s = bias
        for i in 0..<e.count { s += weights[i] * e[i] }
        return 1 / (1 + exp(-s))
    }

    struct TrainingOptions {
        var epochs = 800
        var learningRate = 0.05
        var l2 = 0.01
        var batchSize = 32
        var seed: UInt64 = 42
    }

    /// Trains on all samples. Classes are weighted so each counts equally.
    static func train(positives: [[Double]], negatives: [[Double]], options: TrainingOptions = .init()) -> LogisticModel? {
        guard let dim = (positives.first ?? negatives.first)?.count, dim > 0,
              !positives.isEmpty, !negatives.isEmpty else { return nil }
        let all = positives + negatives
        guard all.allSatisfy({ $0.count == dim }) else { return nil }

        // Per-feature mean and standard deviation.
        var mean = [Double](repeating: 0, count: dim)
        for x in all { for i in 0..<dim { mean[i] += x[i] } }
        for i in 0..<dim { mean[i] /= Double(all.count) }
        var std = [Double](repeating: 0, count: dim)
        for x in all { for i in 0..<dim { std[i] += (x[i] - mean[i]) * (x[i] - mean[i]) } }
        for i in 0..<dim { std[i] = max((std[i] / Double(all.count)).squareRoot(), 1e-6) }

        var model = LogisticModel(mean: mean, std: std, weights: [Double](repeating: 0, count: dim * 2), bias: 0)
        model.positives = positives.count
        model.negatives = negatives.count

        // Pre-expand once into a flat array for speed.
        let width = dim * 2
        var xs = [Double](); xs.reserveCapacity(all.count * width)
        for x in all { xs.append(contentsOf: model.expand(x)) }
        let ys = [Double](repeating: 1, count: positives.count) + [Double](repeating: 0, count: negatives.count)
        let n = Double(all.count)
        let wPos = n / (2 * Double(positives.count))
        let wNeg = n / (2 * Double(negatives.count))

        var order = Array(0..<all.count)
        var rng = SplitMix64(seed: options.seed)
        var w = model.weights
        var b = 0.0
        var grad = [Double](repeating: 0, count: width)

        for _ in 0..<options.epochs {
            order.shuffle(using: &rng)
            var start = 0
            while start < order.count {
                let end = min(start + options.batchSize, order.count)
                for i in 0..<width { grad[i] = 0 }
                var gb = 0.0
                for k in start..<end {
                    let row = order[k]
                    let base = row * width
                    var s = b
                    for i in 0..<width { s += w[i] * xs[base + i] }
                    let p = 1 / (1 + exp(-s))
                    let y = ys[row]
                    let cw = y > 0.5 ? wPos : wNeg
                    let err = (p - y) * cw
                    for i in 0..<width { grad[i] += err * xs[base + i] }
                    gb += err
                }
                let m = Double(end - start)
                for i in 0..<width {
                    w[i] -= options.learningRate * (grad[i] / m + options.l2 * w[i])
                }
                b -= options.learningRate * gb / m
                start = end
            }
        }
        model.weights = w
        model.bias = b
        return model
    }

    /// Trains on a shuffled 80% to measure accuracy on the other 20%, then trains the final model on everything.
    static func trainWithValidation(positives: [[Double]], negatives: [[Double]], options: TrainingOptions = .init()) -> LogisticModel? {
        var rng = SplitMix64(seed: options.seed &+ 7)
        let pos = positives.shuffled(using: &rng)
        let neg = negatives.shuffled(using: &rng)
        let pCut = Int(Double(pos.count) * 0.8), nCut = Int(Double(neg.count) * 0.8)

        var accuracy: Double?
        if pCut > 0, nCut > 0, pCut < pos.count, nCut < neg.count,
           let probe = train(positives: Array(pos[..<pCut]), negatives: Array(neg[..<nCut]), options: options) {
            let testPos = pos[pCut...], testNeg = neg[nCut...]
            // Balanced accuracy, so a lopsided test split can't look better than it is.
            let tp = Double(testPos.filter { probe.probability($0) >= 0.5 }.count) / Double(testPos.count)
            let tn = Double(testNeg.filter { probe.probability($0) < 0.5 }.count) / Double(testNeg.count)
            accuracy = (tp + tn) / 2
        }
        guard var model = train(positives: positives, negatives: negatives, options: options) else { return nil }
        model.accuracy = accuracy
        return model
    }
}

/// Raw samples kept so the model can be retrained after feedback. Oldest samples drop first.
struct TrainingSet: Codable {
    var positives: [[Double]] = []
    var negatives: [[Double]] = []
    static let cap = 3000

    mutating func add(positives p: [[Double]] = [], negatives n: [[Double]] = []) {
        positives.append(contentsOf: p)
        negatives.append(contentsOf: n)
        if positives.count > Self.cap { positives.removeFirst(positives.count - Self.cap) }
        if negatives.count > Self.cap { negatives.removeFirst(negatives.count - Self.cap) }
    }
}

/// Everything learned from calibration, saved to models.json.
struct ModelFile: Codable {
    var smile: LogisticModel?
    var smileData = TrainingSet()
    /// Average of each smile feature during the relaxed calibration step (debug tick marks).
    var smileRelaxedMeans: [Double]?
    var gaze: LogisticModel?
    var gazeData = TrainingSet()
    /// Calm motion energy measured during the relaxed step.
    var calmMotion: Double?
}

enum ModelKind: String {
    case smile, gaze
}

/// Loads, saves and retrains the personal models. Safe to call from any thread.
final class ModelStore {
    static let shared = ModelStore(url: Paths.models)

    private let url: URL
    private let state: Locked<ModelFile>
    private let trainQueue = DispatchQueue(label: "steady.train", qos: .utility)

    /// Called on the main thread after any model changes.
    var onChange: (() -> Void)?

    init(url: URL) {
        self.url = url
        var file = ModelFile()
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(ModelFile.self, from: data) {
            file = decoded
        }
        state = Locked(file)
    }

    var file: ModelFile { state.get() }
    var smile: LogisticModel? { state.get().smile }
    var gaze: LogisticModel? { state.get().gaze }

    func save() {
        let snapshot = state.get()
        trainQueue.async { [url] in
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func update(_ change: (inout ModelFile) -> Void) {
        state.update(change)
        save()
        notify()
    }

    private func notify() {
        DispatchQueue.main.async { self.onChange?() }
    }

    /// Replaces the calibration data for a model and trains it. Completion runs on the main thread.
    func calibrate(_ kind: ModelKind, positives: [[Double]], negatives: [[Double]],
                   completion: @escaping (LogisticModel?) -> Void) {
        trainQueue.async {
            var set = TrainingSet()
            set.add(positives: positives, negatives: negatives)
            let model = LogisticModel.trainWithValidation(positives: set.positives, negatives: set.negatives)
            if let model {
                self.state.update { file in
                    switch kind {
                    case .smile: file.smile = model; file.smileData = set
                    case .gaze: file.gaze = model; file.gazeData = set
                    }
                }
                self.save()
                self.notify()
            }
            DispatchQueue.main.async { completion(model) }
        }
    }

    /// Adds feedback samples and retrains in the background.
    func addFeedback(_ kind: ModelKind, positives: [[Double]] = [], negatives: [[Double]] = [],
                     completion: ((LogisticModel?) -> Void)? = nil) {
        trainQueue.async {
            var set = TrainingSet()
            self.state.update { file in
                switch kind {
                case .smile: file.smileData.add(positives: positives, negatives: negatives); set = file.smileData
                case .gaze: file.gazeData.add(positives: positives, negatives: negatives); set = file.gazeData
                }
            }
            let model = LogisticModel.trainWithValidation(positives: set.positives, negatives: set.negatives)
            if let model {
                self.state.update { file in
                    switch kind {
                    case .smile: file.smile = model
                    case .gaze: file.gaze = model
                    }
                }
            }
            self.save()
            self.notify()
            DispatchQueue.main.async { completion?(model) }
        }
    }

    func deleteAll() {
        state.set(ModelFile())
        // Same serial queue as saving, so a save that was already queued can't bring the file back.
        trainQueue.sync { try? FileManager.default.removeItem(at: url) }
        notify()
    }
}
