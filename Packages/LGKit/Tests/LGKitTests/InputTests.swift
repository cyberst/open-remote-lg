import XCTest
@testable import LGKit

final class InputTextDiffTests: XCTestCase {
    func testAppendDeleteAndNoop() {
        XCTAssertEqual(TextDiff.ops(from: "", to: "abc"), [.insert("abc")])
        XCTAssertEqual(TextDiff.ops(from: "abc", to: "abcd"), [.insert("d")])
        XCTAssertEqual(TextDiff.ops(from: "abcd", to: "ab"), [.delete(2)])
        XCTAssertEqual(TextDiff.ops(from: "abc", to: ""), [.delete(3)])
        XCTAssertEqual(TextDiff.ops(from: "same", to: "same"), [])
    }

    func testMidStringEditDeletesBackAndRetypes() {
        // Typo fixed near the end: cheaper to delete back than to resend everything.
        XCTAssertEqual(TextDiff.ops(from: "hello wrold", to: "hello world"), [.delete(4), .insert("orld")])
    }

    func testEarlyEditInLongTextReplaces() {
        let old = "the quick brown fox jumps over the lazy dog"
        let new = "A" + old.dropFirst()
        XCTAssertEqual(TextDiff.ops(from: old, to: String(new)), [.replace(String(new))])
    }

    func testPasteOverSelectionReplacesWhenCheaper() {
        XCTAssertEqual(TextDiff.ops(from: "abcdefghij", to: "x"), [.replace("x")])
    }

    func testEmojiDeletionFallsBackToReplace() {
        XCTAssertEqual(TextDiff.ops(from: "hi 👋🏽", to: "hi "), [.replace("hi ")])
        XCTAssertEqual(TextDiff.ops(from: "👋", to: ""), [.replace("")])
        // Inserting an emoji is unambiguous.
        XCTAssertEqual(TextDiff.ops(from: "hi", to: "hi 👋"), [.insert(" 👋")])
    }

    func testAccentedCharactersCountAsOne() {
        XCTAssertEqual(TextDiff.ops(from: "café", to: "caf"), [.delete(1)])
    }

    func testApplyingOpsReproducesTarget() {
        let pairs = [("", "x"), ("abc", "abd"), ("hello", "help"), ("Straße", "Strasse"), ("a👍b", "a👍c"), ("xyz", "")]
        for (old, new) in pairs {
            var tv = old
            for op in TextDiff.ops(from: old, to: new) {
                switch op {
                case .delete(let n): tv = String(tv.dropLast(n))
                case .insert(let s): tv += s
                case .replace(let s): tv = s
                }
            }
            XCTAssertEqual(tv, new, "\(old) → \(new)")
        }
    }
}

final class InputTextMirrorTests: XCTestCase {
    func testLocalEditsProduceOpsAndEchoesAreIgnored() {
        var m = TextMirror()
        XCTAssertNil(m.tvReported(KeyboardState(visible: true, currentText: ""), localText: "", now: 0))
        XCTAssertEqual(m.localChanged(to: "ab", now: 1), [.insert("ab")])
        // TV echoes an intermediate state shortly after; must not clobber the field.
        XCTAssertNil(m.tvReported(KeyboardState(visible: true, currentText: "a"), localText: "ab", now: 1.1))
        XCTAssertEqual(m.localChanged(to: "abc", now: 1.2), [.insert("c")])
    }

    func testAdoptsTVTextWhenFieldFocusedOrChangedWhileIdle() {
        var m = TextMirror()
        XCTAssertEqual(m.tvReported(KeyboardState(visible: true, currentText: "cats"), localText: "", now: 0), "cats")
        XCTAssertEqual(m.localChanged(to: "cat", now: 1), [.delete(1)])
        XCTAssertEqual(m.tvReported(KeyboardState(visible: true, currentText: "dogs"), localText: "cat", now: 5), "dogs")
        XCTAssertEqual(m.tvText, "dogs")
    }

    func testOutOfSyncRewritesWholeField() {
        var m = TextMirror()
        _ = m.localChanged(to: "abc", now: 0)
        m.markOutOfSync()
        XCTAssertEqual(m.localChanged(to: "abcd", now: 1), [.replace("abcd")])
        XCTAssertEqual(m.localChanged(to: "abcde", now: 2), [.insert("e")])
    }

    func testHiddenKeyboardDeactivates() {
        var m = TextMirror()
        _ = m.tvReported(KeyboardState(visible: true, currentText: ""), localText: "", now: 0)
        XCTAssertTrue(m.tvFieldActive)
        XCTAssertNil(m.tvReported(KeyboardState(visible: false, currentText: nil), localText: "", now: 1))
        XCTAssertFalse(m.tvFieldActive)
        // Re-focusing a field adopts its text even mid-typing.
        _ = m.localChanged(to: "x", now: 2)
        XCTAssertEqual(m.tvReported(KeyboardState(visible: true, currentText: "q"), localText: "x", now: 2.1), "q")
    }
}

final class InputPointerAcceleratorTests: XCTestCase {
    func testSlowMovesAccumulateViaRemainder() {
        var acc = PointerAccelerator(sensitivity: 1)
        var total = 0.0
        // 0.3 pt per 1/60 s is very slow; individually below one pixel.
        for _ in 0..<30 { total += acc.process(PointerDelta(dx: 0.3, dy: 0), dt: 1.0 / 60).dx }
        XCTAssertGreaterThan(total, 9) // 30 × 0.3 × 1.2 = 10.8 → at least 10 whole pixels
        XCTAssertLessThanOrEqual(total, 11)
    }

    func testOutputIsWholePixels() {
        var acc = PointerAccelerator()
        for i in 1...20 {
            let o = acc.process(PointerDelta(dx: Double(i) * 0.37, dy: -Double(i) * 0.71), dt: 0.016)
            XCTAssertEqual(o.dx, o.dx.rounded()); XCTAssertEqual(o.dy, o.dy.rounded())
        }
    }

    func testFastMovesGetMoreGainAndSensitivityScales() {
        let acc = PointerAccelerator(sensitivity: 1)
        XCTAssertEqual(acc.gain(forSpeed: 10), 1.2, accuracy: 1e-9)
        XCTAssertEqual(acc.gain(forSpeed: 5000), 4.0, accuracy: 1e-9)
        XCTAssertGreaterThan(acc.gain(forSpeed: 800), acc.gain(forSpeed: 200))
        XCTAssertEqual(PointerAccelerator(sensitivity: 2).gain(forSpeed: 10), 2.4, accuracy: 1e-9)
    }

    func testZeroDtDoesNotExplode() {
        var acc = PointerAccelerator()
        let o = acc.process(PointerDelta(dx: 5, dy: 0), dt: 0)
        XCTAssertLessThanOrEqual(abs(o.dx), 20)
    }

    func testDirectionPreserved() {
        var acc = PointerAccelerator()
        let o = acc.process(PointerDelta(dx: -10, dy: 4), dt: 0.016)
        XCTAssertLessThan(o.dx, 0); XCTAssertGreaterThan(o.dy, 0)
    }
}

final class InputMotionToPointerTests: XCTestCase {
    let flat = Vector3(x: 0, y: 0, z: -1)      // screen facing up, pointing the top edge at the TV
    let upright = Vector3(x: 0, y: -1, z: 0)   // phone held vertically, screen facing the user

    func testDeadZoneSuppressesTremor() {
        var m = MotionToPointer(smoothing: 1)
        var total = PointerDelta.zero
        for i in 0..<120 {
            let jitter = (i % 2 == 0 ? 1.0 : -1.0) * 0.02
            let d = m.process(rotationRate: Vector3(x: jitter, y: jitter, z: jitter), gravity: flat, dt: 1.0 / 60)
            total.dx += d.dx; total.dy += d.dy
        }
        XCTAssertEqual(total, .zero)
    }

    func testTurningRightMovesRightWhenFlat() {
        var m = MotionToPointer(smoothing: 1)
        // Turning right (clockwise seen from above) is negative rotation about "up" (= +z when flat).
        var dx = 0.0
        for _ in 0..<30 { dx += m.process(rotationRate: Vector3(x: 0, y: 0, z: -1), gravity: flat, dt: 1.0 / 60).dx }
        XCTAssertGreaterThan(dx, 0)
    }

    func testTurningRightMovesRightWhenUpright() {
        var m = MotionToPointer(smoothing: 1)
        // Upright, "up" is +y; turning right is negative rotation about y.
        var dx = 0.0, dy = 0.0
        for _ in 0..<30 {
            let d = m.process(rotationRate: Vector3(x: 0, y: -1, z: 0), gravity: upright, dt: 1.0 / 60)
            dx += d.dx; dy += d.dy
        }
        XCTAssertGreaterThan(dx, 0)
        XCTAssertEqual(dy, 0)
    }

    func testTiltingUpMovesUp() {
        var m = MotionToPointer(smoothing: 1)
        var dy = 0.0
        for _ in 0..<30 { dy += m.process(rotationRate: Vector3(x: 1, y: 0, z: 0), gravity: flat, dt: 1.0 / 60).dy }
        XCTAssertLessThan(dy, 0)
    }

    func testMagnitudeMatchesScale() {
        var m = MotionToPointer(pixelsPerRadian: 1000, sensitivity: 1, deadZone: 0, smoothing: 1)
        var dx = 0.0
        // 0.5 rad/s for 1 s = 0.5 rad → 500 px.
        for _ in 0..<60 { dx += m.process(rotationRate: Vector3(x: 0, y: 0, z: -0.5), gravity: flat, dt: 1.0 / 60).dx }
        XCTAssertEqual(dx, 500, accuracy: 1)
    }

    func testSmoothingRampsAndResetClears() {
        var m = MotionToPointer(pixelsPerRadian: 1000, deadZone: 0, smoothing: 0.3)
        let first = m.process(rotationRate: Vector3(x: 0, y: 0, z: -3), gravity: flat, dt: 1.0 / 60).dx
        var later = 0.0
        for _ in 0..<20 { later = m.process(rotationRate: Vector3(x: 0, y: 0, z: -3), gravity: flat, dt: 1.0 / 60).dx }
        XCTAssertLessThan(first, later)
        m.reset()
        XCTAssertEqual(m.process(rotationRate: .zero, gravity: flat, dt: 1.0 / 60), .zero)
    }
}

final class InputPointerEventQueueTests: XCTestCase {
    func testMovesCoalesceAndAreRateLimited() {
        var q = PointerEventQueue(interval: 1.0 / 60)
        q.enqueue(.move(dx: 1, dy: 0, drag: false), now: 0)
        XCTAssertEqual(q.dequeue(now: 0), .move(dx: 1, dy: 0, drag: false))
        q.enqueue(.move(dx: 2, dy: 1, drag: false), now: 0.001)
        q.enqueue(.move(dx: 3, dy: 1, drag: false), now: 0.002)
        XCTAssertEqual(q.count, 1)
        XCTAssertNil(q.dequeue(now: 0.005), "too soon after the last send")
        XCTAssertEqual(q.nextSendTime() ?? 0, 1.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(q.dequeue(now: 0.02), .move(dx: 5, dy: 2, drag: false))
        XCTAssertTrue(q.isEmpty)
    }

    func testClickKeepsOrderAndIsNotRateLimited() {
        var q = PointerEventQueue()
        q.enqueue(.move(dx: 1, dy: 1, drag: false), now: 0)
        q.enqueue(.click, now: 0)
        q.enqueue(.move(dx: 4, dy: 4, drag: false), now: 0)
        XCTAssertEqual(q.dequeue(now: 0), .move(dx: 1, dy: 1, drag: false))
        XCTAssertEqual(q.dequeue(now: 0.001), .click)
        XCTAssertNil(q.dequeue(now: 0.002))
        XCTAssertEqual(q.dequeue(now: 0.02), .move(dx: 4, dy: 4, drag: false))
    }

    func testStaleMovesAreDroppedButClicksSurvive() {
        var q = PointerEventQueue(staleAfter: 0.3)
        q.enqueue(.move(dx: 50, dy: 0, drag: false), now: 0)
        q.enqueue(.click, now: 0.1)
        q.enqueue(.scroll(dx: 0, dy: 9), now: 0.1)
        XCTAssertEqual(q.dequeue(now: 1.0), .click)
        XCTAssertNil(q.dequeue(now: 1.0))
        XCTAssertTrue(q.isEmpty)
    }

    func testDragAndPlainMovesDoNotMerge() {
        var q = PointerEventQueue()
        q.enqueue(.move(dx: 1, dy: 0, drag: false), now: 0)
        q.enqueue(.move(dx: 1, dy: 0, drag: true), now: 0)
        q.enqueue(.scroll(dx: 0, dy: 1), now: 0)
        q.enqueue(.scroll(dx: 0, dy: 2), now: 0)
        q.enqueue(.move(dx: 0, dy: 0, drag: false), now: 0) // follows a drag → kept as its release
        XCTAssertEqual(q.count, 4)
    }
}

final class InputPointerDragReleaseTests: XCTestCase {
    func testZeroMoveAfterDragIsKeptAsRelease() {
        var q = PointerEventQueue(staleAfter: 0.3)
        q.enqueue(.move(dx: 0, dy: 0, drag: false), now: 0)   // nothing to release
        XCTAssertTrue(q.isEmpty)
        q.enqueue(.move(dx: 5, dy: 0, drag: true), now: 0)
        q.enqueue(.move(dx: 0, dy: 0, drag: false), now: 0)
        q.enqueue(.move(dx: 3, dy: 0, drag: false), now: 0)    // must not merge into the release
        XCTAssertEqual(q.count, 3)
        // Even when stale (stalled socket), the release survives.
        XCTAssertEqual(q.dequeue(now: 5), .move(dx: 0, dy: 0, drag: false))
        XCTAssertNil(q.dequeue(now: 5))
        XCTAssertTrue(q.isEmpty)
    }

    func testRemoveAllKeepsRelease() {
        var q = PointerEventQueue()
        q.enqueue(.move(dx: 5, dy: 0, drag: true), now: 0)
        q.enqueue(.move(dx: 0, dy: 0, drag: false), now: 0)
        q.removeAll()
        XCTAssertEqual(q.dequeue(now: 0), .move(dx: 0, dy: 0, drag: false))
    }
}

final class InputTouchpadInterpreterTests: XCTestCase {
    func p(_ x: Double, _ y: Double) -> TouchPoint { TouchPoint(x: x, y: y) }

    func testTapClicks() {
        var t = TouchpadInterpreter()
        XCTAssertEqual(t.began(id: 1, at: p(10, 10), time: 0), [])
        XCTAssertEqual(t.moved(id: 1, to: p(11, 10), time: 0.05), [.move(PointerDelta(dx: 1, dy: 0), dt: 0.05, drag: false)])
        XCTAssertEqual(t.ended(id: 1, time: 0.1), [.click])
    }

    func testDragMovesButDoesNotClick() {
        var t = TouchpadInterpreter()
        _ = t.began(id: 1, at: p(0, 0), time: 0)
        _ = t.moved(id: 1, to: p(30, 0), time: 0.05)
        XCTAssertEqual(t.ended(id: 1, time: 0.1), [])
    }

    func testLongHoldIsNotATap() {
        var t = TouchpadInterpreter()
        _ = t.began(id: 1, at: p(0, 0), time: 0)
        XCTAssertEqual(t.ended(id: 1, time: 0.4), [])
    }

    func testLongPressStartsDrag() {
        var t = TouchpadInterpreter()
        _ = t.began(id: 1, at: p(0, 0), time: 0)
        XCTAssertEqual(t.tick(time: 0.2), [])
        XCTAssertEqual(t.tick(time: 0.55), [.dragBegan])
        XCTAssertEqual(t.tick(time: 0.6), [])
        XCTAssertTrue(t.isDragging)
        XCTAssertEqual(t.moved(id: 1, to: p(5, 5), time: 0.7), [.move(PointerDelta(dx: 5, dy: 5), dt: 0.7, drag: true)])
        XCTAssertEqual(t.ended(id: 1, time: 1), [.dragEnded])
    }

    func testMovingPreventsLongPress() {
        var t = TouchpadInterpreter()
        _ = t.began(id: 1, at: p(0, 0), time: 0)
        _ = t.moved(id: 1, to: p(40, 0), time: 0.1)
        XCTAssertEqual(t.tick(time: 1), [])
    }

    func testTwoFingerScroll() {
        var t = TouchpadInterpreter()
        _ = t.began(id: 1, at: p(0, 0), time: 0)
        _ = t.began(id: 2, at: p(40, 0), time: 0.02)
        XCTAssertEqual(t.moved(id: 1, to: p(0, -4), time: 0.05), [])  // centroid moved 2 (< slop)
        let a = t.moved(id: 2, to: p(40, -10), time: 0.06)            // centroid moved 5 more → scrolling
        XCTAssertEqual(a.first, .scrollBegan)
        XCTAssertEqual(a.last, .scroll(PointerDelta(dx: 0, dy: -5)))
        XCTAssertEqual(t.ended(id: 1, time: 0.3), [.scrollEnded])
        // Remaining finger must not move the cursor.
        XCTAssertEqual(t.moved(id: 2, to: p(80, 80), time: 0.35), [])
        XCTAssertEqual(t.ended(id: 2, time: 0.4), [])
        XCTAssertEqual(t.began(id: 3, at: p(0, 0), time: 1), [])
        XCTAssertEqual(t.ended(id: 3, time: 1.05), [.click])
    }

    func testTwoFingerTap() {
        var t = TouchpadInterpreter()
        _ = t.began(id: 1, at: p(0, 0), time: 0)
        _ = t.began(id: 2, at: p(40, 0), time: 0.01)
        XCTAssertEqual(t.ended(id: 1, time: 0.1), [.twoFingerTap])
        XCTAssertEqual(t.ended(id: 2, time: 0.12), [])
    }

    func testThirdFingerCancels() {
        var t = TouchpadInterpreter()
        _ = t.began(id: 1, at: p(0, 0), time: 0)
        _ = t.began(id: 2, at: p(40, 0), time: 0.01)
        _ = t.began(id: 3, at: p(80, 0), time: 0.02)
        XCTAssertEqual(t.ended(id: 1, time: 0.1), [])
        XCTAssertEqual(t.ended(id: 2, time: 0.1), [])
        XCTAssertEqual(t.ended(id: 3, time: 0.1), [])
    }

    func testCancelledTouchDoesNotClick() {
        var t = TouchpadInterpreter()
        _ = t.began(id: 1, at: p(0, 0), time: 0)
        XCTAssertEqual(t.ended(id: 1, time: 0.05, cancelled: true), [])
    }
}
