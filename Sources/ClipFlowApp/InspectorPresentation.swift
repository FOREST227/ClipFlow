import Combine
import Foundation

@MainActor
protocol InspectorAnimationDriving: AnyObject {
    func animate(from: CGFloat, to: CGFloat, duration: TimeInterval,
                 update: @escaping (CGFloat) -> Void, completion: @escaping () -> Void)
    func cancel()
}

/// Only the small motion subtree observes this channel, not the list owner.
@MainActor
final class InspectorMotionProgress: ObservableObject {
    @Published private(set) var value: CGFloat
    init(value: CGFloat = 0) { self.value = min(1, max(0, value.isFinite ? value : 0)) }
    func setValue(_ value: CGFloat) {
        guard value.isFinite else { return }
        let clamped = min(1, max(0, value))
        if self.value != clamped { self.value = clamped }
    }
}

/// Keep an outgoing inspector mounted and blocking until its real completion.
@MainActor
final class InspectorPresentation: ObservableObject {
    enum Phase: Equatable { case closed, opening, open, closing }
    struct Snapshot: Equatable {
        var phase: Phase
        var itemID: UUID?
        var revision: UInt64
    }
    @Published private(set) var snapshot = Snapshot(phase: .closed, itemID: nil, revision: 0)
    let motion = InspectorMotionProgress()
    private let driver: any InspectorAnimationDriving
    private var afterClose: (() -> Void)?
    var blocksBackground: Bool { snapshot.phase != .closed }

    init(driver: any InspectorAnimationDriving) { self.driver = driver }

    func open(itemID: UUID, reduceMotion: Bool) {
        if snapshot.itemID == itemID, snapshot.phase == .open || snapshot.phase == .opening { return }
        let switchingItem = snapshot.itemID != nil && snapshot.itemID != itemID
        let revision = snapshot.revision &+ 1
        afterClose = nil
        snapshot = Snapshot(phase: .opening, itemID: itemID, revision: revision)
        driver.cancel()
        if switchingItem { motion.setValue(0) }
        drive(to: 1, duration: reduceMotion ? 0.11 : 0.28, revision: revision)
    }

    func dismiss(reduceMotion: Bool, afterClose action: (() -> Void)? = nil) {
        guard snapshot.phase != .closed, snapshot.phase != .closing else { return }
        let revision = snapshot.revision &+ 1
        afterClose = action
        snapshot = Snapshot(phase: .closing, itemID: snapshot.itemID, revision: revision)
        driver.cancel()
        drive(to: 0, duration: reduceMotion ? 0.11 : 0.20, revision: revision)
    }

    func reset() {
        afterClose = nil
        snapshot = Snapshot(phase: .closed, itemID: nil, revision: snapshot.revision &+ 1)
        driver.cancel()
        motion.setValue(0)
    }

    func invalidateIfMissing(availableIDs: Set<UUID>) {
        if let id = snapshot.itemID, !availableIDs.contains(id) { reset() }
    }

    private func drive(to target: CGFloat, duration: TimeInterval, revision: UInt64) {
        let start = motion.value
        let completion: () -> Void = { [weak self] in
            guard let self, self.snapshot.revision == revision,
                  self.snapshot.phase == (target == 1 ? .opening : .closing) else { return }
            self.motion.setValue(target)
            if target == 1 {
                self.snapshot = Snapshot(phase: .open, itemID: self.snapshot.itemID, revision: revision)
            } else {
                let action = self.afterClose
                self.afterClose = nil
                self.snapshot = Snapshot(phase: .closed, itemID: nil, revision: revision)
                action?()
            }
        }
        guard start != target else { completion(); return }
        driver.animate(from: start, to: target, duration: duration * Double(abs(target - start)),
            update: { [weak self] value in
                guard let self, self.snapshot.revision == revision else { return }
                self.motion.setValue(value)
            }, completion: completion)
    }
}
