@testable import BCRSurfaceDomain
import BCRFoundation
import Foundation
import Observation
import XCTest

final class SurfaceKernelBindingCacheTests: XCTestCase {
    private let one = BCRControlID.encoder(row: 1, 1)
    private let two = BCRControlID.encoder(row: 1, 2)
    private let button = BCRControlID.button(row: 1, 1)

    private func fixture() -> SurfaceConfiguration {
        .init(name: "cache", parameters: [
            .init(id: "p", name: "P", group: "g"), .init(id: "q", name: "Q", group: "g")
        ], assignments: [.init(control: one, target: .parameter("p")), .init(control: two, target: .parameter("q"))],
        pages: [.init(id: "alternate", name: "Alternate", assignments: [
            .init(control: one, target: .parameter("q")), .init(control: two, target: .parameter("p"))
        ])])
    }

    private func check(_ configuration: SurfaceConfiguration, _ control: BCRControlID,
                       file: StaticString = #filePath, line: UInt = #line)
    {
        // Independent original 366 ordered first-match; no candidate output seeds it.
        let original = configuration.assignments.firstIndex { $0.control == control }
        XCTAssertEqual(configuration.kernelAssignmentIndex(for: control), original, file: file, line: line)
        XCTAssertEqual(configuration.assignment(for: control), original.map { configuration.assignments[$0] },
                       file: file, line: line)
    }

    func testRepeatedRealGettersReuseOneDerivedControlIndex() {
        let configuration = fixture()
        let builds = configuration.kernelBindingIndexBuildCount
        XCTAssertEqual(builds, 1)
        for _ in 0 ..< 10000 {
            check(configuration, one)
            check(configuration, two)
        }
        XCTAssertEqual(configuration.kernelBindingIndexBuildCount, builds)
    }

    func testAssignmentPageAndCopiedValueEditsRebuildOnlyTheirOwnIndex() throws {
        let original = fixture()
        var edited = original
        let initial = edited.kernelBindingIndexBuildCount
        try edited.assign(.init(control: one, target: .parameter("q")))
        XCTAssertGreaterThan(edited.kernelBindingIndexBuildCount, initial)
        XCTAssertEqual(original.assignment(for: one)?.target, .parameter("p"))
        XCTAssertEqual(edited.assignment(for: one)?.target, .parameter("q"))
        check(original, one); check(edited, one)
        edited.clearAssignment(for: two)
        check(edited, two)
        XCTAssertNil(edited.kernelAssignmentIndex(for: two))
        check(original, two)
        try edited.selectPage("alternate")
        check(edited, one); check(edited, two)
        XCTAssertEqual(edited.assignment(for: two)?.target, .parameter("p"))
        try edited.assign(.init(control: two, target: .parameter("q")))
        check(edited, two)
        var another = edited
        try another.selectPage(nil)
        check(another, two)
        XCTAssertNil(another.kernelAssignmentIndex(for: two))
        XCTAssertNotNil(edited.kernelAssignmentIndex(for: two))
        edited.deletePage("alternate")
        XCTAssertNil(edited.activePageID)
        check(edited, one); check(edited, two)
        let beforeFailure = edited
        let buildsBeforeFailure = edited.kernelBindingIndexBuildCount
        XCTAssertThrowsError(try edited.assign(.init(control: button, target: .runMacro("missing"))))
        XCTAssertEqual(edited, beforeFailure)
        XCTAssertEqual(edited.kernelBindingIndexBuildCount, buildsBeforeFailure)
        check(edited, button); check(edited, one)
        try edited.addPage(.init(id: "new", name: "New", assignments: [
            .init(control: one, target: .parameter("p"))
        ]))
        try edited.selectPage("new")
        check(edited, one); check(edited, two)
        XCTAssertEqual(edited.assignment(for: one)?.target, .parameter("p"))
        XCTAssertNil(edited.kernelAssignmentIndex(for: two))
    }

    func testMacroAndParameterRemovalKeepCachedOffsetsAligned() throws {
        var configuration = fixture()
        try configuration.addMacro(.init(id: "macro", name: "Macro", actions: [.set("p", 20)]))
        try configuration.assign(.init(control: button, target: .runMacro("macro")))
        check(configuration, button)
        configuration.deleteMacro("macro")
        check(configuration, button)
        XCTAssertNil(configuration.kernelAssignmentIndex(for: button))
        configuration.removeParameter("p")
        check(configuration, one); check(configuration, two)
        XCTAssertNil(configuration.kernelAssignmentIndex(for: one))
        XCTAssertEqual(configuration.assignment(for: two)?.target, .parameter("q"))
        try configuration.selectPage("alternate")
        check(configuration, one); check(configuration, two)
        XCTAssertEqual(configuration.assignment(for: one)?.target, .parameter("q"))
        XCTAssertNil(configuration.kernelAssignmentIndex(for: two))
    }

    func testMetadataDecodeAndCacheHistoryPreserveOriginalEqualityAndCodableBytes() throws {
        let original = fixture()
        var roundTrip = original
        try roundTrip.selectPage("alternate")
        try roundTrip.selectPage(nil)
        XCTAssertGreaterThan(roundTrip.kernelBindingIndexBuildCount, original.kernelBindingIndexBuildCount)
        XCTAssertEqual(roundTrip, original)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let originalBytes = try encoder.encode(original)
        XCTAssertEqual(try encoder.encode(roundTrip), originalBytes)
        let shape = try XCTUnwrap(JSONSerialization.jsonObject(with: originalBytes) as? [String: Any])
        XCTAssertEqual(Set(shape.keys), ["version", "name", "parameters", "assignments", "pages", "macros"])
        XCTAssertEqual(shape["version"] as? Int, 10)
        XCTAssertEqual(SurfaceConfiguration.currentVersion, 10)
        var metadata = original
        var parameter = try XCTUnwrap(metadata.parameter("p"))
        parameter.name = "Renamed"; parameter.unit = "unit"
        let beforeMetadata = metadata.kernelBindingIndexBuildCount
        try metadata.updateParameter(parameter)
        XCTAssertEqual(metadata.kernelBindingIndexBuildCount, beforeMetadata)
        check(metadata, one); check(original, one)
        XCTAssertEqual(metadata.assignment(for: one), original.assignment(for: one))
        let decoded = try JSONDecoder().decode(SurfaceConfiguration.self, from: encoder.encode(metadata))
        XCTAssertEqual(decoded.kernelBindingIndexBuildCount, 1)
        check(decoded, one); check(decoded, two)
        XCTAssertEqual(decoded, metadata)
        XCTAssertEqual(try encoder.encode(decoded), try encoder.encode(metadata))
        var changedDecoded = decoded
        try changedDecoded.selectPage("alternate")
        changedDecoded.clearAssignment(for: one)
        check(changedDecoded, one); check(decoded, one)
        XCTAssertEqual(decoded.assignment(for: one)?.target, .parameter("p"))
        XCTAssertNil(changedDecoded.assignment(for: one))
        XCTAssertEqual(decoded.activePageID, nil)
        XCTAssertEqual(changedDecoded.activePageID, "alternate")
    }

    @MainActor
    func testDiagnosticMemoTracksActualLanguageABAAndValueCopies() async throws {
        let previous = L10n.language
        defer { L10n.setLanguage(previous) }
        L10n.setLanguage(.english)
        let original = fixture()
        check(original, one)
        let enabled = ProcessInfo.processInfo.environment["BCR_J3_SHADOW_ROOT"] != nil
        XCTAssertEqual(original.bindingDiagnosticPreparationCount, enabled ? 1 : 0)
        check(original, two)
        XCTAssertEqual(original.bindingDiagnosticPreparationCount, enabled ? 1 : 0)
        let first = L10n.diagnosticLanguageSnapshot
        L10n.setLanguage(.chinese)
        L10n.setLanguage(.english)
        let second = L10n.diagnosticLanguageSnapshot
        XCTAssertEqual(first.language, second.language)
        XCTAssertNotEqual(first.revision, second.revision)
        check(original, one)
        XCTAssertEqual(original.bindingDiagnosticPreparationCount, enabled ? 2 : 0)
        var copied = original
        try copied.assign(.init(control: one, target: .parameter("q")))
        check(copied, one); check(original, one)
        XCTAssertEqual(copied.bindingDiagnosticPreparationCount, enabled ? 1 : 0)
        XCTAssertEqual(original.bindingDiagnosticPreparationCount, enabled ? 2 : 0)
        let decoded = try JSONDecoder().decode(SurfaceConfiguration.self, from: JSONEncoder().encode(copied))
        check(decoded, one)
        XCTAssertEqual(decoded.bindingDiagnosticPreparationCount, enabled ? 1 : 0)
        XCTAssertEqual(original.assignment(for: one)?.target, .parameter("p"))
        XCTAssertEqual(decoded.assignment(for: one)?.target, .parameter("q"))
    }

    func testJ4MapMemoUsesFullBytesAndRemainsBoundedAcrossCopiesAndMutations() throws {
        let enabled = ProcessInfo.processInfo.environment["BCR_J4_SHADOW_ROOT"] != nil
        let initial = FeedbackJ4Trace.hardwareMapMemoStatistics
        let original = HardwareMap.mockPreset()
        func checkMap(_ map: HardwareMap) throws {
            let actual = FeedbackJ4Trace.hardwareMap(map)
            if enabled {
                let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(map))
                XCTAssertEqual(try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]),
                               try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]))
            } else { XCTAssertTrue(actual is NSNull) }
        }
        try checkMap(original)
        try checkMap(original)
        var copied = original
        copied.version = original.version + 1000
        try checkMap(copied); try checkMap(original)
        for version in 2000 ..< 2020 {
            var overflow = original; overflow.version = version
            try checkMap(overflow)
        }
        let final = FeedbackJ4Trace.hardwareMapMemoStatistics
        if enabled {
            XCTAssertGreaterThanOrEqual(final.hits - initial.hits, 2)
            XCTAssertGreaterThanOrEqual(final.misses - initial.misses, 21)
            XCTAssertEqual(final.entries, 16)
        } else {
            XCTAssertEqual(final.hits, 0); XCTAssertEqual(final.misses, 0); XCTAssertEqual(final.entries, 0)
        }
        XCTAssertEqual(original.version, HardwareMap.currentVersion)
        XCTAssertEqual(copied.version, original.version + 1000)
    }

    @MainActor
    func testWarmDiagnosticHitPreservesOriginalTrackedLanguageDependency() async throws {
        let originalLanguage = L10n.language
        defer { L10n.setLanguage(originalLanguage) }
        L10n.setLanguage(.english)
        let configuration = fixture()
        _ = configuration.assignment(for: one) // Warm outside the tracking scope.
        let changed = DiagnosticChangeCount()
        let result = withObservationTracking {
            configuration.assignment(for: one)
        } onChange: { changed.increment() }
        XCTAssertEqual(result?.target, .parameter("p"))
        L10n.setLanguage(.chinese)
        let enabled = ProcessInfo.processInfo.environment["BCR_J3_SHADOW_ROOT"] != nil
        XCTAssertEqual(changed.value, enabled ? 1 : 0)
    }

    @MainActor
    func testEmptyDiagnosticHitDoesNotAddTrackedLanguageDependency() async throws {
        let originalLanguage = L10n.language
        defer { L10n.setLanguage(originalLanguage) }
        L10n.setLanguage(.english)
        let configuration = SurfaceConfiguration(name: "empty")
        _ = configuration.assignment(for: one)
        let changed = DiagnosticChangeCount()
        let result = withObservationTracking { configuration.assignment(for: one) }
            onChange: { changed.increment() }
        XCTAssertNil(result)
        L10n.setLanguage(.chinese)
        XCTAssertEqual(changed.value, 0)
    }
}

private final class DiagnosticChangeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
