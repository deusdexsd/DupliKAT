import Accelerate
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Odcisk „jak to wygląda / jak brzmi” — do szukania tego samego materiału w innym eksporcie, rozmiarze albo kodeku.
public struct MediaFingerprint: Codable, Sendable, Hashable {
    /// Czas trwania w sekundach (0 dla zdjęć).
    public var duration: Double
    /// dHash klatek (zdjęcie = 1 wartość, wideo = kilka klatek rozłożonych po długości).
    public var frames: [UInt64]
    /// Obwiednia głośności (RMS co 100 ms, pierwsze 2 minuty). Tylko audio.
    public var envelope: [Float]
    /// Wektory cech obrazu z Vision (VNFeaturePrint, 768 × Float32 na klatkę, sklejone). To one decydują o podobieństwie —
    /// dHash sam myli np. różne produkty na białym tle.
    public var features: Data

    public init(duration: Double = 0, frames: [UInt64] = [], envelope: [Float] = [], features: Data = Data()) {
        self.duration = duration; self.frames = frames; self.envelope = envelope; self.features = features
    }

    public var vectors: [[Float]] {
        let all = features.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard let dim = FeaturePrint.dimension(all.count, frames: max(1, frames.count)) else { return [] }
        return stride(from: 0, to: all.count, by: dim).map { Array(all[$0..<min(all.count, $0 + dim)]) }
    }
}

/// Wektor cech obrazu z frameworku Vision (ta sama technologia, której używa aplikacja Zdjęcia do „podobnych”).
public enum FeaturePrint {
    /// Stały rozmiar wejścia. Vision jest czuły na rozdzielczość: ten sam obraz w 160 px i 512 px dawał odległość 0,68
    /// (jak zupełnie inne zdjęcie). Po sprowadzeniu obu do 224 px: 0,35, a eksport 320 px vs oryginał 0,08.
    static let inputSide = 224

    public static func vector(_ image: CGImage) -> [Float]? {
        guard let input = normalized(image) else { return nil }
        let req = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: input, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results?.first as? VNFeaturePrintObservation, obs.elementType == .float else { return nil }
        var v = obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { v = v.map { $0 / norm } }
        return v
    }

    static func normalized(_ image: CGImage) -> CGImage? {
        let scale = Double(inputSide) / Double(max(image.width, image.height))
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func dimension(_ total: Int, frames: Int) -> Int? {
        guard total > 0, total % frames == 0 else { return total > 0 ? total : nil }
        return total / frames
    }

    public static func pack(_ vs: [[Float]]) -> Data { vs.flatMap { $0 }.withUnsafeBufferPointer { Data(buffer: $0) } }

    /// Odległość euklidesowa (0 = identyczne, ~0,1 = inny rozmiar/kompresja, ~0,35 = wariant, >0,7 = inne zdjęcie).
    public static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var d: Float = 0
        vDSP_distancesq(a, 1, b, 1, &d, vDSP_Length(a.count))
        return d.squareRoot()
    }

    /// Wszystkie pary bliższe niż `maxDistance`. Liczone blokami jako mnożenie macierzy (Accelerate), więc
    /// 10 000 zdjęć to ~sekunda zamiast minut porównań para po parze.
    public static func neighborPairs(_ vectors: [[Float]], maxDistance: Float) -> [(Int, Int, Float)] {
        let n = vectors.count
        guard n > 1, let dim = vectors.first?.count, dim > 0, vectors.allSatisfy({ $0.count == dim }) else { return [] }
        let flat = vectors.flatMap { $0 }
        let minDot = 1 - maxDistance * maxDistance / 2 // dla wektorów jednostkowych: d² = 2 − 2·cos
        var pairs: [(Int, Int, Float)] = []
        let block = 256
        var out = [Float](repeating: 0, count: block * n)
        for start in stride(from: 0, to: n, by: block) {
            let rows = min(block, n - start)
            flat.withUnsafeBufferPointer { all in
                out.withUnsafeMutableBufferPointer { c in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(n), Int32(dim), 1,
                                all.baseAddress! + start * dim, Int32(dim), all.baseAddress!, Int32(dim), 0, c.baseAddress!, Int32(n))
                }
            }
            for r in 0..<rows {
                let i = start + r
                for j in (i + 1)..<n where out[r * n + j] >= minDot {
                    pairs.append((i, j, max(0, 2 - 2 * out[r * n + j]).squareRoot()))
                }
            }
        }
        return pairs
    }
}

public enum PerceptualHash {
    /// dHash 64-bit: obraz zmniejszony do 9×8 w skali szarości, bit = czy piksel jest jaśniejszy od sąsiada po prawej.
    /// Odporny na zmianę rozmiaru, kompresję i lekką korekcję koloru; czuły na kadr i treść.
    public static func dHash(_ image: CGImage) -> UInt64? {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                hash <<= 1
                if pixels[y * w + x] > pixels[y * w + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    @inline(__always) public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Mała miniatura przez ImageIO — dla RAW-ów i JPG-ów z aparatu zwykle używa osadzonego podglądu, więc jest szybko.
    /// Jeśli osadzona miniatura jest za mała (JPG-i z Lightrooma mają w EXIF ~160 px), dekodujemy właściwy obraz —
    /// inaczej oryginał i jego eksport dostają różne odciski, bo Vision jest czuły na rozdzielczość.
    public static func thumbnail(_ url: URL, maxPixel: Int = 128) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        func make(always: Bool) -> CGImage? {
            let opts: [CFString: Any] = [
                always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: false,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        let quick = make(always: false)
        if let quick, max(quick.width, quick.height) >= min(maxPixel, 300) { return quick }
        return make(always: true) ?? quick
    }
}

public enum MediaAnalyzer {
    static let videoSamplePoints: [Double] = [0.1, 0.3, 0.5, 0.7, 0.9]

    public static func image(_ url: URL) -> MediaFingerprint? {
        guard let t = PerceptualHash.thumbnail(url, maxPixel: 384), let h = PerceptualHash.dHash(t), let v = FeaturePrint.vector(t) else { return nil }
        return MediaFingerprint(frames: [h], features: FeaturePrint.pack([v]))
    }

    public static func video(_ url: URL) async -> MediaFingerprint? {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 384, height: 384)
        // Dokładne klatki: z tolerancją każdy plik (inny kodek = inne klatki kluczowe) dawał inną klatkę,
        // a przy szybko ciętych rolkach to już zupełnie inny obraz.
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var frames: [UInt64] = []
        var vectors: [[Float]] = []
        for p in videoSamplePoints {
            let t = CMTime(seconds: d.seconds * p, preferredTimescale: 600)
            guard let img = try? await gen.image(at: t).image, let h = PerceptualHash.dHash(img), let v = FeaturePrint.vector(img) else { continue }
            frames.append(h); vectors.append(v)
        }
        guard !frames.isEmpty else { return nil }
        return MediaFingerprint(duration: d.seconds, frames: frames, features: FeaturePrint.pack(vectors))
    }

    /// Obwiednia głośności: dekoduje do mono 8 kHz, liczy RMS co 100 ms. Wystarczy do rozpoznania tego samego nagrania
    /// w innym formacie (WAV vs MP3 vs AAC), niezależnie od bitrate.
    public static func audio(_ url: URL, maxSeconds: Double = 120) async -> MediaFingerprint? {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0.2,
              let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let rate = 8000.0
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        out.alwaysCopiesSampleData = false
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: min(d.seconds, maxSeconds), preferredTimescale: 600))
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        let window = Int(rate / 10)
        var env: [Float] = []
        var acc: Float = 0
        var n = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == kCMBlockBufferNoErr, let ptr else { continue }
            let count = length / MemoryLayout<Float>.size
            ptr.withMemoryRebound(to: Float.self, capacity: count) { s in
                for i in 0..<count {
                    acc += s[i] * s[i]; n += 1
                    if n == window { env.append((acc / Float(n)).squareRoot()); acc = 0; n = 0 }
                }
            }
        }
        guard env.count >= 3 else { return nil }
        return MediaFingerprint(duration: d.seconds, envelope: env)
    }

    // MARK: Porównania (0…1, 1 = to samo)

    /// Mediana odległości Vision między odpowiadającymi sobie klatkami (0 = to samo).
    public static func visualDistance(_ a: MediaFingerprint, _ b: MediaFingerprint) -> Float {
        let va = a.vectors, vb = b.vectors
        let n = min(va.count, vb.count)
        guard n > 0 else { return 2 }
        // Mediana, nie średnia: jedna klatka w momencie cięcia/przejścia nie przekreśla całego porównania.
        let ds = (0..<n).map { FeaturePrint.distance(va[$0 * va.count / n], vb[$0 * vb.count / n]) }.sorted()
        return n % 2 == 1 ? ds[n / 2] : (ds[n / 2 - 1] + ds[n / 2]) / 2
    }

    /// Odległość → procent podobieństwa pokazywany w UI.
    public static func similarity(fromDistance d: Float) -> Double { max(0, min(1, 1 - Double(d))) }

    /// Korelacja obwiedni głośności (z tolerancją przesunięcia do ±0,5 s — różne kodeki dodają ciszę na początku).
    public static func audioSimilarity(_ a: MediaFingerprint, _ b: MediaFingerprint) -> Double {
        let x = normalized(a.envelope), y = normalized(b.envelope)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var best = -1.0
        for lag in -5...5 {
            var s = 0.0, c = 0
            for i in 0..<x.count {
                let j = i + lag
                guard j >= 0, j < y.count else { continue }
                s += Double(x[i] * y[j]); c += 1
            }
            if c >= min(x.count, y.count) / 2, c > 2 { best = max(best, s / Double(c)) }
        }
        return max(0, best)
    }

    static func normalized(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return [] }
        let mean = v.reduce(0, +) / Float(v.count)
        let sd = (v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(v.count)).squareRoot()
        guard sd > 1e-6 else { return [] } // cisza albo stały ton — nie da się rzetelnie porównać
        return v.map { ($0 - mean) / sd }
    }

    public static func durationsMatch(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= max(0.6, max(a, b) * 0.01)
    }
}

/// Szukanie podobnych zdjęć, wideo i audio.
public struct SimilarityFinder: Sendable {
    public struct Thresholds: Sendable {
        /// Maksymalna odległość Vision (zmierzone na prawdziwych plikach: inny rozmiar/kompresja 0,03–0,13,
        /// ten sam produkt w innym kolorze ~0,35, inne zdjęcia > 0,7).
        public var imageDistance: Float
        public var videoDistance: Float
        /// Minimalna korelacja głośności (0…1).
        public var audio: Double
        public init(imageDistance: Float = 0.25, videoDistance: Float = 0.25, audio: Double = 0.90) {
            self.imageDistance = imageDistance; self.videoDistance = videoDistance; self.audio = audio
        }
    }

    public var walk: WalkOptions
    public var thresholds: Thresholds
    public var cache: HashCache?
    public var concurrency: Int

    public init(walk: WalkOptions, thresholds: Thresholds = .init(), cache: HashCache? = nil, concurrency: Int = 4) {
        self.walk = walk; self.thresholds = thresholds; self.cache = cache; self.concurrency = concurrency
    }

    public func run(roots: [URL], kinds: Set<MediaKind>, progress: ProgressHandler? = nil) async throws -> [DuplicateGroup] {
        var w = walk
        w.kinds = kinds
        let files = try FileWalker.files(in: roots, options: w, progress: progress)
        let prints = try await fingerprints(files, progress: progress)
        progress?(ScanProgress(phase: .comparing, total: files.count))
        var groups: [DuplicateGroup] = []
        for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            let items = files.compactMap { f in prints[f.id].map { (f, $0) } }.filter { $0.0.kind == kind }
            groups += try compare(items, kind: kind)
        }
        cache?.save()
        progress?(ScanProgress(phase: .done))
        return DuplicateFinder.sorted(groups)
    }

    func fingerprints(_ files: [ScannedFile], progress: ProgressHandler?) async throws -> [String: MediaFingerprint] {
        var result: [String: MediaFingerprint] = [:]
        var pending: [ScannedFile] = []
        for f in files {
            if let m = cache?.get(f)?.media { result[f.id] = m } else { pending.append(f) }
        }
        let total = files.count
        var done = result.count
        let cache = self.cache
        try await withThrowingTaskGroup(of: (String, MediaFingerprint?).self) { group in
            var it = pending.makeIterator()
            func addNext() -> Bool {
                guard let f = it.next() else { return false }
                group.addTask {
                    try Task.checkCancellation()
                    let fp: MediaFingerprint?
                    switch f.kind {
                    case .image: fp = MediaAnalyzer.image(f.url)
                    case .video: fp = await MediaAnalyzer.video(f.url)
                    case .audio: fp = await MediaAnalyzer.audio(f.url)
                    default: fp = nil
                    }
                    if let fp { cache?.update(f) { $0.media = fp } }
                    return (f.id, fp)
                }
                return true
            }
            for _ in 0..<max(1, concurrency) where addNext() {}
            while let (id, fp) = try await group.next() {
                if let fp { result[id] = fp }
                done += 1
                if done % 5 == 0 || done == total { progress?(ScanProgress(phase: .fingerprinting, done: done, total: total, current: URL(fileURLWithPath: id).lastPathComponent)) }
                _ = addNext()
            }
        }
        return result
    }

    func compare(_ items: [(ScannedFile, MediaFingerprint)], kind: MediaKind) throws -> [DuplicateGroup] {
        guard items.count > 1 else { return [] }
        var pairs: [(Int, Int, Double)] = [] // (i, j, podobieństwo 0…1)
        switch kind {
        case .image:
            let vs = items.map { $0.1.vectors.first ?? [] }
            let valid = vs.indices.filter { !vs[$0].isEmpty }
            for (a, b, d) in FeaturePrint.neighborPairs(valid.map { vs[$0] }, maxDistance: thresholds.imageDistance) {
                pairs.append((valid[a], valid[b], MediaAnalyzer.similarity(fromDistance: d)))
            }
        case .video, .audio:
            // Porównujemy tylko pliki o zbliżonej długości (posortowane po czasie → okno przesuwne).
            let order = items.indices.sorted { items[$0].1.duration < items[$1].1.duration }
            for (a, i) in order.enumerated() {
                try Task.checkCancellation()
                for j in order[(a + 1)...] {
                    guard MediaAnalyzer.durationsMatch(items[i].1.duration, items[j].1.duration) else { break }
                    if kind == .video {
                        let d = MediaAnalyzer.visualDistance(items[i].1, items[j].1)
                        if d <= thresholds.videoDistance { pairs.append((i, j, MediaAnalyzer.similarity(fromDistance: d))) }
                    } else {
                        let s = MediaAnalyzer.audioSimilarity(items[i].1, items[j].1)
                        if s >= thresholds.audio { pairs.append((i, j, s)) }
                    }
                }
            }
        default: break
        }
        return Self.starClusters(count: items.count, pairs: pairs).map { members in
            let files = DuplicateFinder.ordered(members.map { items[$0.0].0 })
            let sim = members.dropFirst().map(\.1).min() ?? 1
            return DuplicateGroup(id: "p:" + files.map(\.id).joined(separator: "|"), files: files, match: .similar(sim))
        }
    }

    /// Grupowanie „gwiazdą”: środek grupy + wszystko, co jest podobne DO NIEGO. Bez łańcuchów typu A~B~C~…~Z,
    /// przez które seria różnych zdjęć sklejała się w jedną wielką grupę. Środki wybierane od tych z najwięcej sąsiadami.
    static func starClusters(count: Int, pairs: [(Int, Int, Double)]) -> [[(Int, Double)]] {
        var neighbors: [Int: [(Int, Double)]] = [:]
        for (i, j, s) in pairs { neighbors[i, default: []].append((j, s)); neighbors[j, default: []].append((i, s)) }
        var assigned = Set<Int>()
        var out: [[(Int, Double)]] = []
        let centers = neighbors.keys.sorted { (neighbors[$0]!.count, $1) > (neighbors[$1]!.count, $0) }
        for c in centers where !assigned.contains(c) {
            let members = neighbors[c]!.filter { !assigned.contains($0.0) }.sorted { $0.1 > $1.1 }
            guard !members.isEmpty else { continue }
            assigned.insert(c)
            members.forEach { assigned.insert($0.0) }
            out.append([(c, 1)] + members)
        }
        return out
    }
}
