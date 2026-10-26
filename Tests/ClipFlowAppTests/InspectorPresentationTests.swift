import Combine
import XCTest
@testable import ClipFlowApp

@MainActor
final class ManualInspectorDriver: InspectorAnimationDriving {
    struct Run {
        let from: CGFloat
        let to: CGFloat
        let duration: TimeInterval
        let update: (CGFloat) -> Void
        let completion: () -> Void
    }
    var runs: [Run] = []
    var cancelCount = 0
    func animate(from: CGFloat, to: CGFloat, duration: TimeInterval,
                 update: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        runs.append(Run(from: from, to: to, duration: duration, update: update, completion: completion))
    }
    func cancel() { cancelCount += 1 }
    func emit(_ value: CGFloat) { runs.last?.update(value) }
    func finishLatest() {
        guard let run = runs.last else { return }
        run.update(run.to)
        run.completion()
    }
}

@MainActor
final class InspectorPresentationTests: XCTestCase {
    func testClosingRetainsIdentity() {
        let driver = ManualInspectorDriver()
        let state = InspectorPresentation(driver: driver)
        let id = UUID()
        state.open(itemID: id, reduceMotion: false)
        XCTAssertEqual(state.snapshot.phase, .opening)
        driver.finishLatest()
        state.dismiss(reduceMotion: false)
        XCTAssertEqual(state.snapshot.phase, .closing)
        XCTAssertEqual(state.snapshot.itemID, id)
        XCTAssertTrue(state.blocksBackground)
        driver.emit(0.01)
        XCTAssertTrue(state.blocksBackground)
        driver.finishLatest()
        XCTAssertNil(state.snapshot.itemID)
        XCTAssertFalse(state.blocksBackground)
    }

    func testReopenRejectsStaleCompletionAndUpdate() {
        let driver = ManualInspectorDriver()
        let state = InspectorPresentation(driver: driver)
        state.open(itemID: UUID(), reduceMotion: false)
        driver.finishLatest()
        var pastes = 0
        state.dismiss(reduceMotion: false, afterClose: { pastes += 1 })
        let old = driver.runs.last!
        driver.emit(0.4)
        let newID = UUID()
        state.open(itemID: newID, reduceMotion: false)
        let progress = state.motion.value
        old.update(0)
        old.completion()
        XCTAssertEqual(state.snapshot.itemID, newID)
        XCTAssertEqual(state.motion.value, progress)
        XCTAssertTrue(state.blocksBackground)
        driver.finishLatest()
        XCTAssertEqual(state.snapshot.phase, .open)
        XCTAssertEqual(pastes, 0)
    }

    func testReverseStartsAtDisplayedProgressAndUsesSpecDurations() {
        let driver = ManualInspectorDriver()
        let state = InspectorPresentation(driver: driver)
        let id = UUID()
        state.open(itemID: id, reduceMotion: false)
        XCTAssertEqual(driver.runs.last!.duration, 0.28, accuracy: 0.0001)
        driver.emit(0.45)
        state.dismiss(reduceMotion: false)
        XCTAssertEqual(driver.runs.last!.from, 0.45)
        XCTAssertEqual(driver.runs.last!.duration, 0.09, accuracy: 0.0001)
        state.open(itemID: id, reduceMotion: false)
        XCTAssertEqual(driver.runs.last!.from, 0.45)
        driver.finishLatest()
        state.dismiss(reduceMotion: false)
        XCTAssertEqual(driver.runs.last!.duration, 0.20, accuracy: 0.0001)
        driver.finishLatest()
        state.open(itemID: id, reduceMotion: true)
        XCTAssertEqual(driver.runs.last!.duration, 0.11, accuracy: 0.0001)
    }

    func testDismissActionRunsOnceAndRepeatedOpenDoesNotRestart() {
        let driver = ManualInspectorDriver()
        let state = InspectorPresentation(driver: driver)
        let id = UUID()
        state.open(itemID: id, reduceMotion: false)
        state.open(itemID: id, reduceMotion: false)
        XCTAssertEqual(driver.runs.count, 1)
        driver.finishLatest()
        state.open(itemID: id, reduceMotion: false)
        XCTAssertEqual(driver.runs.count, 1)
        var actions = 0
        state.dismiss(reduceMotion: false, afterClose: { actions += 1 })
        state.dismiss(reduceMotion: false, afterClose: { actions += 100 })
        driver.finishLatest()
        driver.finishLatest()
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(state.snapshot.phase, .closed)
    }

    func testResetCancelsPendingPaste() {
        let driver = ManualInspectorDriver()
        let state = InspectorPresentation(driver: driver)
        state.open(itemID: UUID(), reduceMotion: false)
        driver.finishLatest()
        var pastes = 0
        state.dismiss(reduceMotion: false, afterClose: { pastes += 1 })
        let old = driver.runs.last!
        state.reset()
        old.update(0.7)
        old.completion()
        XCTAssertEqual(state.motion.value, 0)
        XCTAssertEqual(pastes, 0)
        XCTAssertFalse(state.blocksBackground)
    }

    func testExpiredItemClearsImmediately() {
        let driver = ManualInspectorDriver()
        let state = InspectorPresentation(driver: driver)
        let id = UUID()
        state.open(itemID: id, reduceMotion: false)
        state.invalidateIfMissing(availableIDs: [id])
        XCTAssertEqual(state.snapshot.itemID, id)
        state.invalidateIfMissing(availableIDs: [])
        XCTAssertNil(state.snapshot.itemID)
        driver.finishLatest()
        XCTAssertNil(state.snapshot.itemID)
    }

    func testMotionTicksDoNotPublishLifecycle() {
        let driver = ManualInspectorDriver()
        let state = InspectorPresentation(driver: driver)
        var changes = 0
        let token = state.$snapshot.dropFirst().sink { _ in changes += 1 }
        state.open(itemID: UUID(), reduceMotion: false)
        let before = changes
        for index in 1...10 { driver.emit(CGFloat(index) / 20) }
        XCTAssertEqual(changes, before)
        withExtendedLifetime(token) {}
    }
}
