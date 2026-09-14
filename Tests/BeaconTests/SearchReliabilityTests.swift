import Foundation
import XCTest
@testable import Beacon

final class AppRankingTests: XCTestCase {
    func testExactAndPrefixMatchesBeatIncidentalHelpers() {
        let tokens = SearchText.tokens("beacon")
        let beacon = AppRanking.rank(name: "Beacon", path: "/Applications/Beacon.app",
                                     tokens: tokens)
        let helper = AppRanking.rank(name: "Beacon Update Helper",
                                     path: "/Applications/Utilities/Beacon Update Helper.app",
                                     bundleIdentifier: "com.example.beacon.helper",
                                     tokens: tokens)

        XCTAssertNotNil(beacon)
        XCTAssertNotNil(helper)
        XCTAssertTrue(beacon! < helper!)
    }

    func testNonMatchingAppsAreRejected() {
        let rank = AppRanking.rank(name: "Adobe Content Synchronizer",
                                   path: "/Applications/Utilities/Adobe Sync/CoreSync.app",
                                   tokens: SearchText.tokens("beac"))
        XCTAssertNil(rank)
    }

    func testUserFacingAppWinsEqualMatchTier() {
        let tokens = SearchText.tokens("bea")
        let normal = AppRanking.rank(name: "Beacon Tools",
                                     path: "/Applications/Beacon Tools.app",
                                     tokens: tokens)
        let helper = AppRanking.rank(name: "Beacon Helper",
                                     path: "/Applications/Utilities/Beacon Helper.app",
                                     bundleIdentifier: "com.example.beacon.helper",
                                     tokens: tokens)

        XCTAssertTrue(normal! < helper!)
    }
}

final class AppStoreCancellationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCancellationIsDistinctFromAnEmptyCatalog() {
        let store = AppStore(roots: [root])

        XCTAssertNil(store.search(tokens: [], isCancelled: { true }))
        XCTAssertEqual(store.search(tokens: [])?.count, 0)
    }

    func testCancelledRefreshDoesNotPoisonNextSearch() throws {
        try createApp(named: "Beacon")
        let store = AppStore(roots: [root])
        XCTAssertEqual(store.search(tokens: SearchText.tokens("beac"))?.map(\.name),
                       ["Beacon"])

        try createApp(named: "Beacon Beta")
        store.refresh()
        XCTAssertNil(store.search(tokens: SearchText.tokens("beac"),
                                  isCancelled: { true }))
        XCTAssertEqual(store.search(tokens: SearchText.tokens("beac"))?.map(\.name),
                       ["Beacon", "Beacon Beta"])
    }

    private func createApp(named name: String) throws {
        let contents = root
            .appendingPathComponent("\(name).app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents,
                                                withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": "com.example.\(name.replacingOccurrences(of: " ", with: ""))",
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml,
                                                      options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}

final class SearchStateTests: XCTestCase {
    func testStaleGenerationIsRejected() {
        let generation = SearchGeneration()
        generation.set(41)
        XCTAssertTrue(generation.isCurrent(41))
        generation.set(42)
        XCTAssertFalse(generation.isCurrent(41))
        XCTAssertTrue(generation.isCurrent(42))
    }

    func testGrowingPageKeepsExistingPrefixStable() {
        let rows = Array(0..<200)
        let first = PageWindow.slice(rows, limit: 80)
        let second = PageWindow.slice(rows, limit: 160)

        XCTAssertTrue(first.hasMore)
        XCTAssertTrue(second.hasMore)
        XCTAssertEqual(Array(second.rows.prefix(first.rows.count)), first.rows)
        XCTAssertEqual(first.rows.count, 80)
        XCTAssertEqual(second.rows.count, 160)
    }

    func testPerformancePolicyLoadsDensePagesWithoutRescanningEveryPage() {
        XCTAssertEqual(SearchPerformancePolicy.pageSize, 160)
        XCTAssertEqual(
            SearchPerformancePolicy.metadataReadLimit(
                pageLimit: 160, previousLimit: 0
            ),
            640
        )
        XCTAssertEqual(
            SearchPerformancePolicy.metadataReadLimit(
                pageLimit: 320, previousLimit: 640
            ),
            1_280
        )
    }
}

final class SearchRefinementTests: XCTestCase {
    func testEachFilterOffersRelevantDistinctRefinements() {
        for type in FileType.allCases {
            let dimensions = RefinementCatalog.dimensions(for: type)
            XCTAssertFalse(dimensions.isEmpty, "\(type) should offer refinements")
            XCTAssertEqual(Set(dimensions.map(\.id)).count, dimensions.count)
            for dimension in dimensions {
                XCTAssertFalse(dimension.options.isEmpty)
                XCTAssertEqual(Set(dimension.options.map(\.id)).count, dimension.options.count)
            }
        }
        XCTAssertEqual(RefinementCatalog.dimensions(for: .messages).map(\.id), ["content"])
        for type in [FileType.pdfs, .developer] {
            XCTAssertEqual(RefinementCatalog.dimensions(for: type).map(\.id), ["location", "time"])
        }
    }

    func testSidebarUsesGlobalSortInsteadOfTimeRangeDimensions() {
        let hidden = Set(["time", "photo-date", "recent-use", "recent-open"])
        for type in FileType.allCases {
            XCTAssertTrue(
                Set(RefinementCatalog.sidebarDimensions(for: type).map(\.id))
                    .isDisjoint(with: hidden)
            )
        }
    }

    func testLocationRefinementUsesPathBoundaries() {
        let home = NSHomeDirectory()
        let selection = RefinementSelection(choices: ["location": "downloads"])
        XCTAssertTrue(RefinementMatcher.matches(
            fileResult(path: home + "/Downloads/photo.png"),
            type: .recents, selection: selection
        ))
        XCTAssertFalse(RefinementMatcher.matches(
            fileResult(path: home + "/Downloads Archive/photo.png"),
            type: .recents, selection: selection
        ))
    }

    func testScreenshotRefinementUsesNameAndKnownFolder() {
        let selection = RefinementSelection(choices: ["location": "screenshots"])
        XCTAssertTrue(RefinementMatcher.matches(
            fileResult(path: "/tmp/Screenshot 2026-07-12.png"),
            type: .recents, selection: selection
        ))
        XCTAssertTrue(RefinementMatcher.matches(
            fileResult(path: NSHomeDirectory() + "/Pictures/Screenshots/capture.png"),
            type: .recents, selection: selection
        ))
        XCTAssertFalse(RefinementMatcher.matches(
            fileResult(path: NSHomeDirectory() + "/Pictures/photo.png"),
            type: .recents, selection: selection
        ))
    }

    func testSelectionsAcrossDimensionsUseAndSemantics() {
        let now = Date()
        let selection = RefinementSelection(choices: [
            "location": "downloads",
            "time": "today"
        ])
        XCTAssertTrue(RefinementMatcher.matches(
            fileResult(path: NSHomeDirectory() + "/Downloads/today.pdf", modified: now),
            type: .all, selection: selection, now: now
        ))
        XCTAssertFalse(RefinementMatcher.matches(
            fileResult(path: NSHomeDirectory() + "/Desktop/today.pdf", modified: now),
            type: .all, selection: selection, now: now
        ))
    }

    func testSanitizationDropsDimensionsFromAnotherFilter() {
        let selection = RefinementSelection(choices: [
            "content": "links",
            "location": "downloads"
        ])
        XCTAssertEqual(
            RefinementCatalog.sanitized(selection, for: .messages),
            RefinementSelection(choices: ["content": "links"])
        )
    }

    func testMessagesOnlyExposeMessageTypeRefinement() {
        XCTAssertEqual(
            RefinementCatalog.sidebarDimensions(for: .messages).map(\.id),
            ["content"]
        )
    }

    func testSelectionRoundTripsForPerFilterPersistence() throws {
        let selection = RefinementSelection(choices: [
            "location": "downloads",
            "time": "week"
        ])
        let encoded = try JSONEncoder().encode(selection)
        XCTAssertEqual(try JSONDecoder().decode(RefinementSelection.self, from: encoded),
                       selection)
    }

    func testPhotosLibraryRefinementMatchesLibraryMediaOnly() {
        let photoSource = RefinementCatalog.dimensions(for: .photos)
            .first { $0.id == "photo-source" }
        let videoLocation = RefinementCatalog.dimensions(for: .videos)
            .first { $0.id == "location" }
        XCTAssertEqual(photoSource?.options.first { $0.id == "photos-library" }?.isEnabled, true)
        XCTAssertEqual(videoLocation?.options.first { $0.id == "photos-library" }?.isEnabled, true)
        var facets = RefinementFacets.empty
        facets.sourceApp = "photos-library"
        for (type, dimension) in [(FileType.photos, "photo-source"), (.videos, "location")] {
            let selection = RefinementSelection(choices: [dimension: "photos-library"])
            XCTAssertTrue(RefinementMatcher.matches(fileResult(path: "/tmp/library-media", facets: facets),
                                                   type: type, selection: selection))
            XCTAssertFalse(RefinementMatcher.matches(fileResult(path: "/tmp/local-media"),
                                                    type: type, selection: selection))
        }
    }

    func testPSDCanBeAddedAndMatchedAsAnImageFormat() {
        let selection = RefinementSelection(choices: ["format": "psd"])
        XCTAssertTrue(RefinementMatcher.matches(
            fileResult(path: "/tmp/design.psd"),
            type: .photos, selection: selection
        ))
        XCTAssertTrue(FileType.photos.filenameExtensions.contains("psd"))
    }

    func testDurationBoundariesRemainExact() {
        let short = RefinementSelection(choices: ["duration": "short"])
        let medium = RefinementSelection(choices: ["duration": "medium"])
        let long = RefinementSelection(choices: ["duration": "long"])
        XCTAssertTrue(RefinementMatcher.matches(
            fileResult(path: "/tmp/a.mov", facets: durationFacets(59.99)),
            type: .videos, selection: short
        ))
        XCTAssertTrue(RefinementMatcher.matches(
            fileResult(path: "/tmp/b.mov", facets: durationFacets(60)),
            type: .videos, selection: medium
        ))
        XCTAssertTrue(RefinementMatcher.matches(
            fileResult(path: "/tmp/c.mov", facets: durationFacets(300)),
            type: .videos, selection: medium
        ))
        XCTAssertTrue(RefinementMatcher.matches(
            fileResult(path: "/tmp/d.mov", facets: durationFacets(300.01)),
            type: .videos, selection: long
        ))
    }

    func testProjectOptionsOnlyIncludeDetectedTypes() {
        var facets = RefinementFacets()
        facets.isProject = true
        facets.category = "git"
        let dimensions = RefinementCatalog.enriched(
            RefinementCatalog.catalogDimensions(for: .folders),
            with: [fileResult(path: "/tmp/repository", isFolder: true, facets: facets)]
        )
        XCTAssertEqual(
            dimensions.first(where: { $0.id == "project" })?.options.map(\.id),
            ["git"]
        )
    }

    func testProjectAndCloudFacetsAreUserSpecific() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            RefinementFacetBuilder.projectCategory(at: root.path), "git"
        )

        let cloudPath = NSHomeDirectory()
            + "/Library/CloudStorage/GoogleDrive-person@example.com/My Drive/Design/file.psd"
        XCTAssertEqual(
            RefinementFacetBuilder.cloudAccount(for: cloudPath),
            "person@example.com"
        )
        XCTAssertEqual(
            RefinementFacetBuilder.cloudContainer(for: cloudPath),
            "Design"
        )
    }

    private func fileResult(path: String, modified: Date? = nil,
                            isFolder: Bool = false,
                            facets: RefinementFacets = .empty) -> SearchResult {
        SearchResult(
            id: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            kind: "File",
            size: nil,
            modified: modified,
            lastUsed: nil,
            dateAdded: nil,
            isFolder: isFolder,
            isApp: false,
            matchKind: .name,
            facets: facets
        )
    }

    private func durationFacets(_ duration: Double) -> RefinementFacets {
        var facets = RefinementFacets()
        facets.duration = duration
        return facets
    }
}

final class RefinementLayoutStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "RefinementLayoutStoreTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testOptionalPSDPersistsWithoutChangingOtherFilters() {
        let key = "layouts"
        let store = RefinementLayoutStore(defaults: defaults, defaultsKey: key)
        let originalVideos = store.layout(for: .videos)
        XCTAssertFalse(
            store.layout(for: .photos).optionIDs["format", default: []].contains("psd")
        )

        store.addOption("psd", dimensionID: "format", for: .photos)
        let reloaded = RefinementLayoutStore(defaults: defaults, defaultsKey: key)

        XCTAssertTrue(
            reloaded.layout(for: .photos).optionIDs["format", default: []].contains("psd")
        )
        XCTAssertEqual(
            reloaded.layout(for: .videos),
            originalVideos
        )
    }

    func testSpecializedDocumentFormatsAreOptIn() {
        let store = RefinementLayoutStore(defaults: defaults, defaultsKey: "layouts")
        XCTAssertFalse(
            store.layout(for: .docs).optionIDs["format", default: []]
                .contains("notebook")
        )
        store.addOption("notebook", dimensionID: "format", for: .docs)
        XCTAssertTrue(
            store.layout(for: .docs).optionIDs["format", default: []]
                .contains("notebook")
        )
        XCTAssertEqual(
            RefinementValueSets.extensions(for: "notebook"), Set(["ipynb"])
        )
    }

    func testDimensionCanBeAddedHiddenReorderedAndReset() {
        let store = RefinementLayoutStore(defaults: defaults, defaultsKey: "layouts")
        XCTAssertFalse(store.layout(for: .videos).dimensionIDs.contains("format"))

        store.addDimension("format", for: .videos)
        XCTAssertTrue(store.layout(for: .videos).dimensionIDs.contains("format"))

        store.moveDimension("format", before: "location", for: .videos)
        XCTAssertEqual(store.layout(for: .videos).dimensionIDs.first, "format")

        store.hideDimension("format", for: .videos)
        XCTAssertFalse(store.layout(for: .videos).dimensionIDs.contains("format"))

        store.addDimension("format", for: .videos)
        store.reset(.videos)
        XCTAssertFalse(store.layout(for: .videos).dimensionIDs.contains("format"))
    }
}

final class MediaFilterTests: XCTestCase {
    func testUniversalFeedUsesSingleRecentsIdentity() {
        XCTAssertEqual(FileType.all.title, "Recents")
        XCTAssertEqual(FileType.all.symbol, "clock")
    }

    func testVideoExtensionsExcludeTypeScriptAmbiguity() {
        XCTAssertTrue(FileType.videos.filenameExtensions.contains("mp4"))
        XCTAssertTrue(FileType.videos.filenameExtensions.contains("mov"))
        XCTAssertFalse(FileType.videos.filenameExtensions.contains("ts"))
    }

    func testBrowsableFileFiltersHaveConcreteExtensionFallbacks() {
        XCTAssertTrue(FileType.docs.filenameExtensions.contains("docx"))
        XCTAssertTrue(FileType.docs.filenameExtensions.contains("md"))
        XCTAssertTrue(FileType.photos.filenameExtensions.contains("png"))
        XCTAssertTrue(FileType.photos.filenameExtensions.contains("heic"))
        XCTAssertTrue(FileType.audio.filenameExtensions.contains("mp3"))
        XCTAssertTrue(FileType.audio.filenameExtensions.contains("m4a"))
    }

    func testDocsAndPDFsRemainDistinctIndexScopes() {
        XCTAssertFalse(
            FileType.docs.contentTypeTrees.contains("public.composite-content")
        )
        XCTAssertFalse(FileType.docs.contentTypeTrees.contains("public.text"))
        XCTAssertFalse(FileType.docs.filenameExtensions.contains("pdf"))
        XCTAssertFalse(FileType.docs.filenameExtensions.contains("svg"))
        XCTAssertFalse(FileType.docs.filenameExtensions.contains("log"))
        XCTAssertEqual(FileType.pdfs.contentTypeTrees, ["com.adobe.pdf"])
        XCTAssertTrue(FileType.photos.filenameExtensions.contains("svg"))
    }
}

final class RecentsStoreTests: XCTestCase {
    func testFreshDownloadIsAvailableBeforeSpotlightIndexesIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(
            at: downloads, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let image = downloads.appendingPathComponent("brand-new.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)

        let rows = RecentsStore(home: root.path).freshItems()
        let record = try XCTUnwrap(rows.first { $0.path == image.path })
        XCTAssertTrue(record.contentTypes.contains("public.image"))
    }
}

final class FolderStoreTests: XCTestCase {
    func testExactFolderNameIsFoundWithoutSpotlight() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = root
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Insider Logos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let rows = FolderStore(home: root).search(tokens: ["insider"])

        XCTAssertEqual(rows.first?.name, "Insider Logos")
    }

    func testFolderSearchDoesNotReturnMatchingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("insider.txt")
        try Data().write(to: file)

        XCTAssertTrue(FolderStore(home: root).search(tokens: ["insider"]).isEmpty)
    }
}
