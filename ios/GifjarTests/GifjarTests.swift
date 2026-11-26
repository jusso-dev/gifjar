import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Gifjar

// MARK: - Fixtures

/// Builds a real animated GIF in memory with ImageIO.
func makeGIF(frames: Int, delay: Double, size: Int = 8) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for i in 0..<frames {
        ctx.setFillColor(CGColor(red: CGFloat(i) / CGFloat(max(frames, 1)), green: 0.5, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    CGImageDestinationFinalize(dest)
    return data as Data
}

func makePNG(width: Int, height: Int) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

// MARK: - Media probing

@Suite struct MediaInfoTests {
    @Test func probesAnimatedGIF() throws {
        let (type, info) = try #require(MediaInfo.probe(makeGIF(frames: 5, delay: 0.2, size: 12)))
        #expect(type == .gif)
        #expect(info.frameCount == 5)
        #expect(info.pixelWidth == 12 && info.pixelHeight == 12)
        #expect(abs(info.duration - 1.0) < 0.01)
    }

    @Test func clampsZeroDelayLikeBrowsers() throws {
        let (_, info) = try #require(MediaInfo.probe(makeGIF(frames: 3, delay: 0)))
        #expect(abs(info.duration - 0.3) < 0.01)
    }

    @Test func probesStillPNG() throws {
        let (type, info) = try #require(MediaInfo.probe(makePNG(width: 30, height: 20)))
        #expect(type == .png)
        #expect(info.frameCount == 1)
        #expect(info.duration == 0)
        #expect(info.pixelWidth == 30 && info.pixelHeight == 20)
    }

    @Test func rejectsNonImages() {
        #expect(MediaInfo.probe(Data("<html></html>".utf8)) == nil)
        #expect(MediaInfo.probe(Data()) == nil)
    }
}

// MARK: - Search

@Suite struct SearchTests {
    func fields(phrases: [String] = [], title: String = "", notes: String = "", tags: [String] = [], summary: String = "", ocr: String = "") -> SearchIndex.Fields {
        .init(phrases: phrases, title: title, notes: notes, tags: tags, summary: summary, ocr: ocr)
    }

    @Test func requiresEveryWord() {
        let f = fields(title: "Dog on skateboard")
        #expect(SearchIndex.score(f, query: "dog skateboard") != nil)
        #expect(SearchIndex.score(f, query: "dog surfboard") == nil)
    }

    @Test func prefersUserPhrasesOverAIGuesses() throws {
        let phrase = try #require(SearchIndex.score(fields(phrases: ["this is fine"]), query: "fine"))
        let summary = try #require(SearchIndex.score(fields(summary: "A fine dog sits in a burning room"), query: "fine"))
        #expect(phrase > summary)
    }

    @Test func exactPhraseBeatsScatteredWords() throws {
        let exact = try #require(SearchIndex.score(fields(phrases: ["deal with it"]), query: "deal with it"))
        let scattered = try #require(SearchIndex.score(fields(phrases: ["it", "with", "deal"]), query: "deal with it"))
        #expect(exact > scattered)
    }

    @Test func matchesPrefixesDiacriticsAndTypos() {
        #expect(SearchIndex.score(fields(tags: ["celebration"]), query: "celeb") != nil)
        #expect(SearchIndex.score(fields(title: "Café vibes"), query: "cafe") != nil)
        #expect(SearchIndex.score(fields(tags: ["surprised"]), query: "suprised") != nil)
        #expect(SearchIndex.score(fields(tags: ["cat"]), query: "dog") == nil)
    }

    @Test func searchesTextInsideImages() {
        #expect(SearchIndex.score(fields(ocr: "ONE DOES NOT SIMPLY"), query: "simply") != nil)
    }

    @Test func editDistance() {
        #expect(SearchIndex.closeEnough("coffee", "cofee"))
        #expect(SearchIndex.closeEnough("excitement", "excitemnet"))
        #expect(!SearchIndex.closeEnough("happy", "angry"))
    }
}

// MARK: - Link metadata

@Suite struct LinkMetadataTests {
    let giphyLike = """
    <html><head>
    <title>Excited Cat GIF - Find &amp; Share on GIPHY</title>
    <meta property="og:title" content="Excited Cat GIF - Find &amp; Share on GIPHY">
    <meta property="og:image" content="https://media.example.com/abc/giphy.webp?cid=1&amp;rid=2">
    <meta name='twitter:image' content='https://media.example.com/abc/200.png'>
    <meta property="og:image:gif" content="https://media.example.com/abc/giphy.gif">
    </head></html>
    """

    @Test func prefersGIFOverStills() throws {
        let urls = LinkMetadata.mediaCandidates(in: giphyLike, baseURL: URL(string: "https://example.com/gifs/x")!)
        #expect(urls.first?.absoluteString == "https://media.example.com/abc/giphy.gif")
        #expect(urls.contains(URL(string: "https://media.example.com/abc/giphy.webp?cid=1&rid=2")!))
        #expect(urls.count == 3)
    }

    @Test func resolvesRelativeURLs() {
        let html = #"<meta property="og:image" content="/img/cat.png">"#
        let urls = LinkMetadata.mediaCandidates(in: html, baseURL: URL(string: "https://site.test/post/1")!)
        #expect(urls == [URL(string: "https://site.test/img/cat.png")!])
    }

    @Test func extractsCleanTitle() {
        #expect(LinkMetadata.title(in: giphyLike) == "Excited Cat")
        #expect(LinkMetadata.title(in: "<title>Just a page</title>") == "Just a page")
    }

    @Test func findsURLInText() {
        #expect(LinkMetadata.firstURL(in: "lol look https://tenor.com/view/x-123 haha")?.host() == "tenor.com")
        #expect(LinkMetadata.firstURL(in: "no links here") == nil)
    }
}

// MARK: - Sync wire format

@Suite struct RemoteItemTests {
    @Test func roundTripsWithLowercaseIDs() throws {
        var item = RemoteItem(id: UUID(), updatedAt: 1_700_000_000_123)
        item.title = "Mind blown"
        item.phrases = ["mind blown", "wow"]
        item.contentType = UTType.gif.identifier
        item.frameCount = 12
        let data = try JSONEncoder().encode(item)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(item.id.uuidString.lowercased()))
        #expect(try JSONDecoder().decode(RemoteItem.self, from: data) == item)
    }

    @Test func decodesTombstone() throws {
        let json = #"{"id":"3f2b6c1e-1111-4222-8333-444455556666","updatedAt":5,"deleted":true}"#
        let item = try JSONDecoder().decode(RemoteItem.self, from: Data(json.utf8))
        #expect(item.deleted == true)
        #expect(item.title == nil)
    }

    @Test func millisecondRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.456)
        #expect(SyncEngine.date(SyncEngine.millis(date)) == date)
    }
}

// MARK: - Frame player

@Suite struct FramePlayerTests {
    @Test func mapsTimeToFrame() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).gif")
        try makeGIF(frames: 4, delay: 0.25).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = try #require(await FramePlayer.make(url: url, maxPixelSize: 64))
        #expect(player.isAnimated)
        #expect(player.frameCount == 4)
        #expect(player.index(at: 0) == 0)
        #expect(player.index(at: 0.26) == 1)
        #expect(player.index(at: 0.99) == 3)
        #expect(await player.frame(at: 2) != nil)
    }
}

// MARK: - Share extension inbox

@Suite struct ShareInboxTests {
    @Test func roundTripsMediaAndMetadataOldestFirst() throws {
        let inbox = ShareInbox(directory: FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let gif = makeGIF(frames: 3, delay: 0.1)

        var shared = ShareRequest(title: "Mind blown", phrase: "mind blown")
        shared.createdAt = Date(timeIntervalSince1970: 100)
        try inbox.enqueue(shared, media: gif, type: .gif)
        var link = ShareRequest(link: URL(string: "https://tenor.com/view/x-1")!)
        link.createdAt = Date(timeIntervalSince1970: 50)
        try inbox.enqueue(link)
        // A staging folder the extension never finished must be ignored.
        try FileManager.default.createDirectory(at: inbox.directory.appending(path: ".partial"), withIntermediateDirectories: true)

        let pending = inbox.pending()
        #expect(pending.count == 2)
        #expect(pending.first?.request.link?.host() == "tenor.com")
        let media = try #require(pending.last)
        #expect(try inbox.mediaData(for: media.request, in: media.folder) == gif)
        #expect(media.request.phrase == "mind blown")

        inbox.remove(media.folder)
        #expect(inbox.pending().count == 1)
    }

    @Test func resolvesSharedProviders() async throws {
        let gif = makeGIF(frames: 2, delay: 0.1)
        let image = NSItemProvider()
        image.registerDataRepresentation(for: .gif) { done in done(gif, nil); return nil }
        #expect(try await MediaResolver.incoming(from: image) == .media(gif))

        let text = NSItemProvider(object: "lol https://tenor.com/view/run-123 ha" as NSString)
        #expect(try await MediaResolver.incoming(from: text) == .link(URL(string: "https://tenor.com/view/run-123")!))
    }

    @Test func onlyNetworkErrorsAreRetried() {
        #expect(ImportError.notAnImage.isPermanent)
        #expect(ImportError.http(404).isPermanent)
        #expect(!ImportError.http(503).isPermanent)
        #expect(!ImportError.http(429).isPermanent)
    }
}
