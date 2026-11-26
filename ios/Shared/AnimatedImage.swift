import ImageIO
import SwiftUI
import UIKit

/// Plays GIF / APNG / animated WebP / HEICS with per-frame timing, or shows a still.
///
/// Frames are decoded downsampled to `maxPixelSize` off the main thread. Small
/// animations are fully cached; large ones decode one frame ahead.
struct AnimatedImage: UIViewRepresentable {
    let url: URL
    var maxPixelSize: CGFloat
    var contentMode: UIView.ContentMode = .scaleAspectFill
    var isPlaying: Bool = true

    @Environment(\.accessibilityPlayAnimatedImages) private var systemAllowsAnimation
    @Environment(\.displayScale) private var displayScale

    func makeUIView(context: Context) -> AnimatedImageView {
        let view = AnimatedImageView()
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: AnimatedImageView, context: Context) {
        view.contentMode = contentMode
        view.load(url: url, maxPixelSize: Int(maxPixelSize * displayScale))
        view.isPlaying = isPlaying && systemAllowsAnimation
    }

    static func dismantleUIView(_ view: AnimatedImageView, coordinator: ()) {
        view.stop()
    }
}

final class AnimatedImageView: UIView {
    private let imageLayer = CALayer()
    private var url: URL?
    private var maxPixelSize = 0
    private var player: FramePlayer?
    private var displayLink: CADisplayLink?
    private var elapsed: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval?
    private var currentIndex = 0

    var isPlaying = false {
        didSet { if oldValue != isPlaying { updateLink() } }
    }

    override var contentMode: UIView.ContentMode {
        didSet { imageLayer.contentsGravity = contentMode == .scaleAspectFit ? .resizeAspect : .resizeAspectFill }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageLayer.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateLink()
    }

    func load(url: URL, maxPixelSize: Int) {
        guard url != self.url || maxPixelSize > self.maxPixelSize else { return }
        let isSameFile = url == self.url
        self.url = url
        self.maxPixelSize = maxPixelSize
        if !isSameFile {
            imageLayer.contents = nil
            elapsed = 0
            currentIndex = 0
        }
        let requestedURL = url
        Task {
            let player = await FramePlayer.make(url: url, maxPixelSize: maxPixelSize)
            guard self.url == requestedURL else { return }
            self.player = player
            if let first = await player?.frame(at: self.currentIndex) {
                self.imageLayer.contents = first
            }
            self.updateLink()
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func updateLink() {
        let shouldRun = isPlaying && window != nil && (player?.isAnimated ?? false)
        if shouldRun, displayLink == nil {
            let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
            // GIFs rarely exceed 50 fps; don't burn ProMotion frames on them.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 60, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastTimestamp = nil
        } else if !shouldRun {
            stop()
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let player, player.isAnimated else { return }
        let now = link.targetTimestamp
        defer { lastTimestamp = now }
        guard let last = lastTimestamp else { return }
        elapsed = (elapsed + (now - last)).truncatingRemainder(dividingBy: player.totalDuration)
        let index = player.index(at: elapsed)
        guard index != currentIndex else { return }
        currentIndex = index
        Task {
            guard let image = await player.frame(at: index), self.currentIndex == index else { return }
            self.imageLayer.contents = image
        }
    }
}

/// Breaks the CADisplayLink → target retain cycle.
private final class DisplayLinkProxy {
    weak var view: AnimatedImageView?
    init(_ view: AnimatedImageView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) { view?.tick(link) }
}

/// Decodes frames off the main actor.
actor FramePlayer {
    nonisolated let frameCount: Int
    nonisolated let delays: [Double]
    nonisolated let totalDuration: Double
    nonisolated let startTimes: [Double]
    nonisolated var isAnimated: Bool { frameCount > 1 && totalDuration > 0 }

    private let source: CGImageSource
    private let maxPixelSize: Int
    private let cacheAll: Bool
    private var cache: [Int: CGImage] = [:]

    private static let fullCacheBudget = 16 * 1024 * 1024

    private init(source: CGImageSource, maxPixelSize: Int) {
        self.source = source
        self.maxPixelSize = maxPixelSize
        frameCount = CGImageSourceGetCount(source)
        delays = frameCount > 1 ? FrameTiming.delays(for: source) : [0]
        totalDuration = delays.reduce(0, +)
        var t = 0.0
        startTimes = delays.map { d in defer { t += d }; return t }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? maxPixelSize
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? maxPixelSize
        let scale = min(1, Double(maxPixelSize) / Double(max(w, h, 1)))
        let bytesPerFrame = Double(w) * scale * Double(h) * scale * 4
        cacheAll = bytesPerFrame * Double(frameCount) <= Double(Self.fullCacheBudget)
    }

    static func make(url: URL, maxPixelSize: Int) async -> FramePlayer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return FramePlayer(source: source, maxPixelSize: max(maxPixelSize, 64))
    }

    nonisolated func index(at time: Double) -> Int {
        // Binary search the frame whose window contains `time`.
        var low = 0, high = startTimes.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if startTimes[mid] <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func frame(at index: Int) -> CGImage? {
        if let cached = cache[index] { return cached }
        let image = FrameTiming.downsample(source, index: index, maxPixel: maxPixelSize)
        if cacheAll {
            cache[index] = image
        } else {
            // Keep only the current frame and prefetch the next.
            cache = image.map { [index: $0] } ?? [:]
            let next = (index + 1) % frameCount
            if let upcoming = FrameTiming.downsample(source, index: next, maxPixel: maxPixelSize) {
                cache[next] = upcoming
            }
        }
        return image
    }
}
