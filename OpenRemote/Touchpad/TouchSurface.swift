import SwiftUI
import UIKit
import LGKit

/// Raw multitouch surface. Feeds every (coalesced) touch sample into `TouchpadInterpreter` and reports
/// the resulting actions. Touch feedback (ripples, finger glow) is drawn with Core Animation layers so
/// it never causes SwiftUI re-renders at touch rate.
struct TouchSurface: UIViewRepresentable {
    var onAction: (TouchpadAction) -> Void

    func makeUIView(context: Context) -> TouchSurfaceView {
        let v = TouchSurfaceView()
        v.onAction = onAction
        return v
    }

    func updateUIView(_ uiView: TouchSurfaceView, context: Context) {
        uiView.onAction = onAction
    }

    static func dismantleUIView(_ uiView: TouchSurfaceView, coordinator: ()) {
        uiView.resetGesture()
    }
}

final class TouchSurfaceView: UIView {
    var onAction: ((TouchpadAction) -> Void)?
    private var interpreter = TouchpadInterpreter()
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 0
    private var glows: [Int: CALayer] = [:]
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { resetGesture() }
    }

    func resetGesture() {
        emit(interpreter.reset())
        ids.removeAll()
        glows.values.forEach { $0.removeFromSuperlayer() }
        glows.removeAll()
        stopTicking()
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = nextID; nextID &+= 1
            ids[ObjectIdentifier(t)] = id
            let p = t.location(in: self)
            emit(interpreter.began(id: id, at: TouchPoint(x: p.x, y: p.y), time: t.timestamp))
            addRipple(at: p)
            addGlow(id: id, at: p)
        }
        startTicking()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let id = ids[ObjectIdentifier(t)] else { continue }
            // Coalesced samples give the full-rate (up to 240 Hz) path between frames.
            let samples = event?.coalescedTouches(for: t) ?? [t]
            for s in samples {
                let p = s.location(in: self)
                emit(interpreter.moved(id: id, to: TouchPoint(x: p.x, y: p.y), time: s.timestamp))
            }
            moveGlow(id: id, to: t.location(in: self))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for t in touches {
            guard let id = ids.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            emit(interpreter.ended(id: id, time: t.timestamp, cancelled: cancelled))
            removeGlow(id: id)
        }
        if ids.isEmpty { stopTicking() }
    }

    private func emit(_ actions: [TouchpadAction]) {
        for a in actions {
            if case .dragBegan = a { glows.values.forEach { pulse($0) } }
            onAction?(a)
        }
    }

    // MARK: Long-press clock

    private func startTicking() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        // Touch timestamps and CADisplayLink share the same clock (seconds since boot).
        emit(interpreter.tick(time: ProcessInfo.processInfo.systemUptime))
    }

    // MARK: Feedback

    private var feedbackColor: CGColor { tintColor.resolvedColor(with: traitCollection).cgColor }

    private func addRipple(at p: CGPoint) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let r: CGFloat = 26
        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)).cgPath
        ring.position = p
        ring.fillColor = nil
        ring.strokeColor = feedbackColor
        ring.lineWidth = 2
        ring.opacity = 0
        layer.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4; scale.toValue = 1.8
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    private func addGlow(id: Int, at p: CGPoint) {
        let size: CGFloat = 44
        let glow = CALayer()
        glow.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        glow.cornerRadius = size / 2
        glow.backgroundColor = feedbackColor
        glow.opacity = 0.18
        glow.position = p
        layer.addSublayer(glow)
        glows[id] = glow
    }

    private func moveGlow(id: Int, to p: CGPoint) {
        guard let g = glows[id] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        g.position = p
        CATransaction.commit()
    }

    private func removeGlow(id: Int) {
        guard let g = glows.removeValue(forKey: id) else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { g.removeFromSuperlayer() }
        g.opacity = 0
        CATransaction.commit()
    }

    private func pulse(_ l: CALayer) {
        l.opacity = 0.35
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1; a.toValue = 1.5; a.duration = 0.18; a.autoreverses = true
        l.add(a, forKey: "pulse")
    }
}
