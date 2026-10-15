import Testing
import Foundation
@testable import TVBox

/// Property-based tests for PlayerGestureLayer.computeSeekTarget.
/// These tests validate that seek target computation is correctly clamped.
///
/// **Validates: Requirements 1.2, 1.3, 1.5, 1.6**

// MARK: - Property 1: Seek target computation is correctly clamped

/// For any currentTime t ∈ [0, duration], any offset (positive or negative, large or small),
/// and duration d > 0, computeSeekTarget returns a value in [0, d].
@Suite("Property 1: Seek target computation is correctly clamped")
struct SeekTargetClampingTests {

    @Test("Seek target is always within [0, duration] for randomized inputs")
    func seekTargetAlwaysClamped() {
        for _ in 0..<200 {
            let duration = Double.random(in: 0.001...36000.0)
            let currentTime = Double.random(in: 0...duration)
            let offset = Double.random(in: -100000...100000)

            let result = PlayerGestureLayer.computeSeekTarget(
                currentTime: currentTime,
                offset: offset,
                duration: duration
            )

            #expect(
                result >= 0,
                "Seek target \(result) should be >= 0 (currentTime=\(currentTime), offset=\(offset), duration=\(duration))"
            )
            #expect(
                result <= duration,
                "Seek target \(result) should be <= duration \(duration) (currentTime=\(currentTime), offset=\(offset))"
            )
        }
    }

    @Test("Seek target clamps to 0 when offset is very negative")
    func seekTargetClampsToZero() {
        for _ in 0..<100 {
            let duration = Double.random(in: 1.0...10000.0)
            let currentTime = Double.random(in: 0...duration)
            // Offset guaranteed to pull below zero
            let offset = -(currentTime + Double.random(in: 1.0...100000.0))

            let result = PlayerGestureLayer.computeSeekTarget(
                currentTime: currentTime,
                offset: offset,
                duration: duration
            )

            #expect(result == 0, "Expected 0 when offset pulls below zero, got \(result)")
        }
    }

    @Test("Seek target clamps to duration when offset is very positive")
    func seekTargetClampsToDuration() {
        for _ in 0..<100 {
            let duration = Double.random(in: 1.0...10000.0)
            let currentTime = Double.random(in: 0...duration)
            // Offset guaranteed to exceed duration
            let offset = (duration - currentTime) + Double.random(in: 1.0...100000.0)

            let result = PlayerGestureLayer.computeSeekTarget(
                currentTime: currentTime,
                offset: offset,
                duration: duration
            )

            #expect(result == duration, "Expected duration \(duration) when offset exceeds bounds, got \(result)")
        }
    }

    @Test("Seek target equals currentTime + offset when within bounds")
    func seekTargetExactWhenInBounds() {
        for _ in 0..<100 {
            let duration = Double.random(in: 10.0...10000.0)
            let currentTime = Double.random(in: 1.0...(duration - 1.0))
            // Ensure offset keeps result within [0, duration]
            let maxPositiveOffset = duration - currentTime - 0.001
            let maxNegativeOffset = -(currentTime - 0.001)
            let offset = Double.random(in: maxNegativeOffset...maxPositiveOffset)

            let result = PlayerGestureLayer.computeSeekTarget(
                currentTime: currentTime,
                offset: offset,
                duration: duration
            )

            let expected = currentTime + offset
            #expect(
                abs(result - expected) < 1e-10,
                "Expected \(expected), got \(result) (currentTime=\(currentTime), offset=\(offset), duration=\(duration))"
            )
        }
    }

    @Test("Seek target handles very small duration")
    func seekTargetSmallDuration() {
        let duration = 0.001
        let currentTime = 0.0005
        let offsets: [Double] = [-100, -1, -0.001, 0, 0.001, 1, 100]

        for offset in offsets {
            let result = PlayerGestureLayer.computeSeekTarget(
                currentTime: currentTime,
                offset: offset,
                duration: duration
            )
            #expect(result >= 0)
            #expect(result <= duration)
        }
    }

    @Test("Seek target with zero offset returns currentTime")
    func seekTargetZeroOffset() {
        for _ in 0..<100 {
            let duration = Double.random(in: 0.001...36000.0)
            let currentTime = Double.random(in: 0...duration)

            let result = PlayerGestureLayer.computeSeekTarget(
                currentTime: currentTime,
                offset: 0,
                duration: duration
            )

            #expect(
                abs(result - currentTime) < 1e-10,
                "With zero offset, result should equal currentTime"
            )
        }
    }

    @Test("Seek target at zero boundary with negative offset stays at 0")
    func seekTargetAtZeroBoundary() {
        for _ in 0..<100 {
            let duration = Double.random(in: 1.0...10000.0)
            let offset = -Double.random(in: 0.001...100000.0)

            let result = PlayerGestureLayer.computeSeekTarget(
                currentTime: 0,
                offset: offset,
                duration: duration
            )

            #expect(result == 0)
        }
    }

    @Test("Seek target at duration boundary with positive offset stays at duration")
    func seekTargetAtDurationBoundary() {
        for _ in 0..<100 {
            let duration = Double.random(in: 1.0...10000.0)
            let offset = Double.random(in: 0.001...100000.0)

            let result = PlayerGestureLayer.computeSeekTarget(
                currentTime: duration,
                offset: offset,
                duration: duration
            )

            #expect(result == duration)
        }
    }
}
