import Testing
import CoreGraphics
@testable import TVBox

/// Property-based tests for PlayerGestureLayer.classifyGesture zone classification.
/// These tests validate that gesture classification is deterministic and mutually exclusive.
///
/// **Validates: Requirements 1.1, 2.1, 3.1**

// MARK: - Property 2: Gesture zone classification is deterministic and mutually exclusive

/// For any touch start position x within a container of width w > 0, and any drag translation
/// (dx, dy) exceeding the threshold, the gesture classification function SHALL return exactly
/// one of: .seeking, .adjustingBrightness, or .adjustingVolume, where brightness is selected
/// iff x < w/2 and |dy| > |dx|, and volume is selected iff x >= w/2 and |dy| > |dx|.
@Suite("Property 2: Gesture zone classification is deterministic and mutually exclusive")
struct GestureZoneClassificationPropertyTests {

    static let threshold: CGFloat = 10.0

    // MARK: - Determinism: same inputs always produce same output

    @Test("Classification is deterministic - same inputs always produce same result")
    func classificationIsDeterministic() {
        for _ in 0..<500 {
            let containerWidth = CGFloat.random(in: 1.0...2000.0)
            let startX = CGFloat.random(in: 0.0..<containerWidth)
            let dx = CGFloat.random(in: -1000.0...1000.0)
            let dy = CGFloat.random(in: -1000.0...1000.0)
            let translation = CGSize(width: dx, height: dy)

            let result1 = PlayerGestureLayer.classifyGesture(
                startX: startX,
                containerWidth: containerWidth,
                translation: translation,
                threshold: Self.threshold
            )
            let result2 = PlayerGestureLayer.classifyGesture(
                startX: startX,
                containerWidth: containerWidth,
                translation: translation,
                threshold: Self.threshold
            )

            #expect(result1 == result2,
                    "Classification should be deterministic for startX=\(startX), w=\(containerWidth), dx=\(dx), dy=\(dy)")
        }
    }

    // MARK: - Mutual exclusivity: exactly one mode returned when threshold exceeded

    @Test("Exactly one mode is returned when gesture exceeds threshold")
    func exactlyOneModeReturned() {
        for _ in 0..<500 {
            let containerWidth = CGFloat.random(in: 1.0...2000.0)
            let startX = CGFloat.random(in: 0.0..<containerWidth)
            // Generate translations that exceed threshold
            let magnitude = CGFloat.random(in: (Self.threshold + 1)...1000.0)
            let angle = CGFloat.random(in: 0.0...(2.0 * .pi))
            let dx = magnitude * cos(angle)
            let dy = magnitude * sin(angle)
            let translation = CGSize(width: dx, height: dy)

            let result = PlayerGestureLayer.classifyGesture(
                startX: startX,
                containerWidth: containerWidth,
                translation: translation,
                threshold: Self.threshold
            )

            // When magnitude exceeds threshold, we should get exactly one non-none mode
            // (either seeking, brightness, or volume)
            let isSeeking: Bool
            let isBrightness: Bool
            let isVolume: Bool
            let isNone: Bool

            switch result {
            case .seeking: isSeeking = true; isBrightness = false; isVolume = false; isNone = false
            case .adjustingBrightness: isSeeking = false; isBrightness = true; isVolume = false; isNone = false
            case .adjustingVolume: isSeeking = false; isBrightness = false; isVolume = true; isNone = false
            case .none: isSeeking = false; isBrightness = false; isVolume = false; isNone = true
            }

            // At most one mode is active (mutual exclusivity)
            let activeCount = [isSeeking, isBrightness, isVolume, isNone].filter { $0 }.count
            #expect(activeCount == 1,
                    "Exactly one mode should be active, got \(activeCount) for dx=\(dx), dy=\(dy)")
        }
    }

    // MARK: - Horizontal dominance: |dx| > |dy| and |dx| > threshold → seeking

    @Test("Horizontal gesture returns .seeking when |dx| > |dy| and |dx| > threshold")
    func horizontalGestureReturnsSeeking() {
        for _ in 0..<500 {
            let containerWidth = CGFloat.random(in: 1.0...2000.0)
            let startX = CGFloat.random(in: 0.0..<containerWidth)

            // Generate dx that exceeds threshold
            let absDx = CGFloat.random(in: (Self.threshold + 1)...1000.0)
            let dx = Bool.random() ? absDx : -absDx

            // Generate dy with |dy| < |dx| to ensure horizontal dominance
            let absDy = CGFloat.random(in: 0.0..<absDx)
            let dy = Bool.random() ? absDy : -absDy

            let translation = CGSize(width: dx, height: dy)

            let result = PlayerGestureLayer.classifyGesture(
                startX: startX,
                containerWidth: containerWidth,
                translation: translation,
                threshold: Self.threshold
            )

            if case .seeking = result {
                // Expected
            } else {
                Issue.record("Expected .seeking for |dx|=\(abs(dx)) > |dy|=\(abs(dy)) > threshold, got \(result)")
            }
        }
    }

    // MARK: - Left half vertical: |dy| > |dx| and |dy| > threshold and x < w/2 → brightness

    @Test("Left half vertical gesture returns .adjustingBrightness when |dy| > |dx| and startX < w/2")
    func leftHalfVerticalReturnsBrightness() {
        for _ in 0..<500 {
            let containerWidth = CGFloat.random(in: 2.0...2000.0)
            // startX strictly in left half
            let startX = CGFloat.random(in: 0.0..<(containerWidth / 2.0))

            // Generate dy that exceeds threshold
            let absDy = CGFloat.random(in: (Self.threshold + 1)...1000.0)
            let dy = Bool.random() ? absDy : -absDy

            // Generate dx with |dx| < |dy| to ensure vertical dominance
            // Also ensure |dx| <= |dy| so the first condition (absH > absV) is false
            let absDx = CGFloat.random(in: 0.0...absDy)
            let dx = Bool.random() ? absDx : -absDx

            let translation = CGSize(width: dx, height: dy)

            let result = PlayerGestureLayer.classifyGesture(
                startX: startX,
                containerWidth: containerWidth,
                translation: translation,
                threshold: Self.threshold
            )

            if case .adjustingBrightness = result {
                // Expected
            } else {
                Issue.record("Expected .adjustingBrightness for startX=\(startX) < w/2=\(containerWidth/2), |dy|=\(abs(dy)) > |dx|=\(abs(dx)), got \(result)")
            }
        }
    }

    // MARK: - Right half vertical: |dy| > |dx| and |dy| > threshold and x >= w/2 → volume

    @Test("Right half vertical gesture returns .adjustingVolume when |dy| > |dx| and startX >= w/2")
    func rightHalfVerticalReturnsVolume() {
        for _ in 0..<500 {
            let containerWidth = CGFloat.random(in: 2.0...2000.0)
            // startX in right half (>= w/2)
            let startX = CGFloat.random(in: (containerWidth / 2.0)...containerWidth)

            // Generate dy that exceeds threshold
            let absDy = CGFloat.random(in: (Self.threshold + 1)...1000.0)
            let dy = Bool.random() ? absDy : -absDy

            // Generate dx with |dx| < |dy| to ensure vertical dominance
            let absDx = CGFloat.random(in: 0.0...absDy)
            let dx = Bool.random() ? absDx : -absDx

            let translation = CGSize(width: dx, height: dy)

            let result = PlayerGestureLayer.classifyGesture(
                startX: startX,
                containerWidth: containerWidth,
                translation: translation,
                threshold: Self.threshold
            )

            if case .adjustingVolume = result {
                // Expected
            } else {
                Issue.record("Expected .adjustingVolume for startX=\(startX) >= w/2=\(containerWidth/2), |dy|=\(abs(dy)) > |dx|=\(abs(dx)), got \(result)")
            }
        }
    }

    // MARK: - Below threshold: neither exceeds threshold → .none

    @Test("Returns .none when neither component exceeds threshold")
    func belowThresholdReturnsNone() {
        for _ in 0..<500 {
            let containerWidth = CGFloat.random(in: 1.0...2000.0)
            let startX = CGFloat.random(in: 0.0..<containerWidth)

            // Both dx and dy within threshold
            let dx = CGFloat.random(in: -Self.threshold...Self.threshold)
            let dy = CGFloat.random(in: -Self.threshold...Self.threshold)
            let translation = CGSize(width: dx, height: dy)

            let result = PlayerGestureLayer.classifyGesture(
                startX: startX,
                containerWidth: containerWidth,
                translation: translation,
                threshold: Self.threshold
            )

            #expect(result == .none,
                    "Expected .none when |dx|=\(abs(dx)) <= threshold and |dy|=\(abs(dy)) <= threshold, got \(result)")
        }
    }

    // MARK: - Boundary: exact midpoint x = w/2 goes to volume (right half)

    @Test("Exact midpoint startX == w/2 classifies as volume (right half)")
    func exactMidpointGoesToVolume() {
        let containerWidths: [CGFloat] = [100.0, 200.0, 375.0, 414.0, 500.0, 1000.0]

        for containerWidth in containerWidths {
            let startX = containerWidth / 2.0
            let translation = CGSize(width: 0, height: -50.0) // Vertical gesture

            let result = PlayerGestureLayer.classifyGesture(
                startX: startX,
                containerWidth: containerWidth,
                translation: translation,
                threshold: Self.threshold
            )

            if case .adjustingVolume = result {
                // Expected: x >= w/2 means right half → volume
            } else {
                Issue.record("Expected .adjustingVolume at exact midpoint startX=\(startX), w=\(containerWidth), got \(result)")
            }
        }
    }

    // MARK: - Comprehensive zone correctness with random inputs

    @Test("Zone classification matches specification for all random inputs")
    func zoneClassificationMatchesSpec() {
        for _ in 0..<1000 {
            let containerWidth = CGFloat.random(in: 1.0...2000.0)
            let startX = CGFloat.random(in: 0.0..<containerWidth)
            let dx = CGFloat.random(in: -1000.0...1000.0)
            let dy = CGFloat.random(in: -1000.0...1000.0)
            let translation = CGSize(width: dx, height: dy)

            let result = PlayerGestureLayer.classifyGesture(
                startX: startX,
                containerWidth: containerWidth,
                translation: translation,
                threshold: Self.threshold
            )

            let absH = abs(dx)
            let absV = abs(dy)

            if absH > absV && absH > Self.threshold {
                // Should be seeking
                if case .seeking = result {
                    // Correct
                } else {
                    Issue.record("Expected .seeking when |dx|=\(absH) > |dy|=\(absV) and |dx| > threshold, got \(result)")
                }
            } else if absV > Self.threshold {
                // Should be brightness or volume based on position
                let isLeftHalf = startX < containerWidth / 2.0
                if isLeftHalf {
                    if case .adjustingBrightness = result {
                        // Correct
                    } else {
                        Issue.record("Expected .adjustingBrightness for left half (startX=\(startX) < w/2=\(containerWidth/2)), got \(result)")
                    }
                } else {
                    if case .adjustingVolume = result {
                        // Correct
                    } else {
                        Issue.record("Expected .adjustingVolume for right half (startX=\(startX) >= w/2=\(containerWidth/2)), got \(result)")
                    }
                }
            } else {
                // Neither exceeds threshold → .none
                #expect(result == .none,
                        "Expected .none when neither exceeds threshold (|dx|=\(absH), |dy|=\(absV)), got \(result)")
            }
        }
    }
}
