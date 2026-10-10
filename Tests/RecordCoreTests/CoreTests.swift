import Foundation
import Testing
@testable import RecordCore

private func sample(_ t: Double, down: Bool = false) -> CursorSample { CursorSample(t: t, x: 0.2 + 0.6 * (t / 20), y: 0.5, down: down) }
// Clicks at 2.0, 2.8 (a burst) and 10.0, each held for a few frames.
private let cursor: [CursorSample] = stride(from: 0.0, through: 20.0, by: 0.1).map { t in
    sample(t, down: [2.0, 2.8, 10.0].contains { t >= $0 - 1e-9 && t < $0 + 0.25 })
}
private func edits(_ f: (inout Edits) -> Void = { _ in }) -> Edits {
    var e = Edits(trim: Trim(start: 0, end: 20)); f(&e); return e
}

@Suite struct Filenames {
    @Test func makesSafeNames() {
        #expect(safeFilename("My demo: take 1/2?") == "My-demo-take-1-2")
        #expect(safeFilename("../../etc/passwd") == "etc-passwd")
        #expect(safeFilename("   ") == "recording")
        #expect(safeFilename(String(repeating: "a", count: 200)).count == 80)
    }
    @Test func normalizesPickedBounds() {
        #expect(normalizeBounds(NRect(x: -100, y: 450, w: 820, h: 900), screen: (1440, 900)) == NRect(x: 0, y: 0.5, w: 0.5, h: 0.5))
        #expect(normalizeBounds(NRect(x: 0, y: 0, w: 10, h: 10), screen: (1440, 900)) == nil)
    }
}

@Suite struct AutoZoom {
    @Test func detectsClickEdgesNotHeldFrames() {
        #expect(clickTimes(cursor).map { ($0 * 100).rounded() / 100 } == [2, 2.8, 10])
    }
    @Test func mergesNearbyClicksAndClamps() {
        let z = autoZooms(cursor, duration: 20)
        #expect(z.count == 2)
        #expect(abs(z[0].start - 1.1) < 1e-6 && abs(z[0].end - 5.4) < 1e-6)
        #expect(abs(z[1].start - 9.1) < 1e-6 && abs(z[1].end - 12.6) < 1e-6)
        #expect(autoZooms([CursorSample(t: 0.1, x: 0, y: 0, down: true)], duration: 1).first.map { ($0.start, $0.end) }! == (0, 1))
    }
    @Test func easesInAndOutWithoutAJolt() {
        let zs = [Zoom(start: 0, end: 3, scale: 2)]
        #expect(zoomAt(zs, 0) == 1)
        #expect(abs(zoomAt(zs, 0.55) - 1.5) < 1e-6)
        #expect(zoomAt(zs, 0.02) - 1 < 0.001) // zero velocity at the start
        #expect(2 - zoomAt(zs, 1.08) < 0.001) // lands softly
        #expect(zoomAt(zs, 1.5) == 2)
        #expect(zoomAt(zs, 3) == 1)
    }
}

@Suite struct CursorIdle {
    // Moves until 3 s, sits still until 8 s, then moves again.
    let activity = cursorActivity(stride(from: 0.0, through: 10.0, by: 1 / 60).map { t in
        CursorSample(t: t, x: t < 3 ? t / 10 : t < 8 ? 0.3 : t / 10 - 0.5, y: 0.5, down: false)
    })
    @Test func fadesOutWhenIdleAndBackOnMovement() {
        #expect(cursorOpacity(activity, 2.5, delay: 2) == 1)          // moving
        #expect(cursorOpacity(activity, 4.9, delay: 2) == 1)          // still, but not for 2 s yet
        #expect(cursorOpacity(activity, 5.5, delay: 2) == 0)          // idle past the delay and the fade
        #expect(abs(cursorOpacity(activity, 5.1, delay: 2) - 0.5) < 0.1) // mid-fade
        #expect(cursorOpacity(activity, 8.05, delay: 2) == 1)         // moving again
        #expect(cursorOpacity(activity, 7.85, delay: 2) > 0)          // fading back in just before
    }
    @Test func aClickCountsAsActivity() {
        let still = [CursorSample(t: 0, x: 0.5, y: 0.5, down: false), CursorSample(t: 5, x: 0.5, y: 0.5, down: true)]
        #expect(cursorActivity(still) == [0, 5])
    }
}

@Suite struct RedrawnCursor {
    @Test func smoothingLagsBehindAndZeroFollowsExactly() {
        let jump = [CursorSample(t: 0, x: 0, y: 0, down: false), CursorSample(t: 1, x: 0, y: 0, down: false), CursorSample(t: 1.001, x: 1, y: 1, down: false)]
        let exact = smoothPath(jump, duration: 3, fps: 60, follow: 0), smooth = smoothPath(jump, duration: 3, fps: 60, follow: 0.075)
        #expect(pathAt(exact, fps: 60, 1.1).x == 1)
        #expect(pathAt(smooth, fps: 60, 1.1).x < 0.6)           // still catching up just after the jump
        #expect(pathAt(smooth, fps: 60, 2.5).x > 0.99)          // settled
    }
    @Test func usesTheLastShapeSetSoFar() {
        let changes = [CursorSample(t: 0.5, x: 0, y: 0, down: false, image: 0), CursorSample(t: 2, x: 0, y: 0, down: false, image: 1)]
        #expect(cursorImageAt(changes, 0) == 0)                 // before the first read: the first shape
        #expect(cursorImageAt(changes, 1) == 0 && cursorImageAt(changes, 2.5) == 1)
        #expect(cursorImageAt([], 1) == nil)
    }
    @Test func oldCursorFilesStillDecode() throws {
        let s = try JSONDecoder().decode([CursorSample].self, from: Data(#"[{"t":0,"x":0.5,"y":0.5,"down":false}]"#.utf8))
        #expect(s.first?.image == nil)
    }
}

@Suite struct MotionBlurAmount {
    @Test func sharpBelowTheThresholdAndCapped() {
        #expect(CursorStyle.blurRadius(speed: 2, strength: 1) == 0)
        #expect(CursorStyle.blurRadius(speed: 40, strength: 1) == 10 && CursorStyle.blurRadius(speed: 40, strength: 0.5) == 5)
        #expect(CursorStyle.blurRadius(speed: 10_000, strength: 1) == 60)
    }
}

@Suite struct ClickEffects {
    @Test func animatesForAShortTimeAfterEachClick() {
        let clicks = clickTimes(cursor) // 2.0, 2.8, 10.0
        #expect(clickAnimation(clicks, 1.9) == nil)
        #expect(clickAnimation(clicks, 2.0)?.k == 0)
        let mid = clickAnimation(clicks, 2.15)!
        #expect(abs(mid.t - 2) < 1e-9 && mid.k > 0.5)             // eased out: past halfway at half the time
        #expect(clickAnimation(clicks, 2.5) == nil)
        #expect(abs(clickAnimation(clicks, 2.9)!.t - 2.8) < 1e-9) // the latest click wins
    }
    @Test func bounceDipsAndComesBack() {
        #expect(ClickEffect.bounceScale(0) == 1 && abs(ClickEffect.bounceScale(1) - 1) < 1e-9)
        #expect(abs(ClickEffect.bounceScale(0.5) - 0.75) < 1e-9)
    }
}

@Suite struct Speeds {
    // 1–9 s kept with 3–6 s cut, 7–9 s at 2× and 0–2 s at 0.5×: 1–2 s plays for 2 s, 2–3 s and 6–7 s at 1×, 7–9 s in 1 s.
    func edits() -> Edits {
        var e = Cuts().cut()
        e.allSpeeds = [SpeedRegion(start: 7, end: 9.5, speed: 2), SpeedRegion(start: 0, end: 2, speed: 0.5)]
        return e
    }
    @Test func splitsTheKeptPartsWhereTheSpeedChanges() {
        let m = edits().timeMap
        #expect(m == [Trim(start: 1, end: 2, speed: 0.5), Trim(start: 2, end: 3), Trim(start: 6, end: 7), Trim(start: 7, end: 9, speed: 2)])
        #expect(outputDuration(m) == 5)
    }
    @Test func mapsOutputTimeThroughTheSpeeds() {
        let m = edits().timeMap
        #expect(outputToSource(m, 1) == 1.5 && outputToSource(m, 2.5) == 2.5 && outputToSource(m, 4.5) == 8)
        #expect(sourceToOutput(m, 8) == 4.5 && sourceToOutput(m, 1.5) == 1)
        for t in stride(from: 0.0, to: 5, by: 0.25) { #expect(abs(sourceToOutput(m, outputToSource(m, t)) - t) < 1e-9) }
    }
    @Test func splitsWithEveryLane() {
        var e = edits()
        e.split(at: 8)
        #expect(e.allSpeeds.map(\.end) == [2, 8, 9.5])
    }
    @Test func zoomsEaseInOutputTime() {
        // A 4 s zoom played at 4× eases exactly like a 1 s zoom at 1×, rather than squeezing a 4 s ease into 1 s.
        var fast = Edits(trim: Trim(start: 0, end: 10), zooms: [Zoom(start: 2, end: 6, scale: 2)])
        fast.allSpeeds = [SpeedRegion(start: 2, end: 6, speed: 4)]
        let a = cameraPath([], fast, duration: 10)
        let b = cameraPath([], Edits(trim: Trim(start: 0, end: 10), zooms: [Zoom(start: 2, end: 3, scale: 2)]), duration: 10)
        for u in stride(from: 0.0, through: 1, by: 0.1) { #expect(abs(cameraAt(a, 2 + 4 * u).z - cameraAt(b, 2 + u).z) < 0.03) }
    }
}

@Suite struct TimelineNavigation {
    @Test func formatsHourLongTimes() {
        #expect(formatTime(0) == "0:00" && formatTime(59.9) == "0:59" && formatTime(3599) == "59:59")
        #expect(formatTime(3600) == "1:00:00" && formatTime(3725) == "1:02:05" && formatTime(-3) == "0:00")
    }

    @Test func listsEditPointsInOrder() {
        var e = Edits(trim: Trim(start: 1, end: 9), zooms: [Zoom(start: 2, end: 4, scale: 2)])
        _ = e.split(at: 6)
        e.markers = [Marker(t: 7.5, name: "Two")]
        e.callouts = [Callout(text: "Hi", start: 4, end: 5, x: 0, y: 0)]
        #expect(e.editPoints == [1, 2, 4, 5, 6, 7.5, 9]) // 4 is both a zoom's end and a callout's start, listed once
    }

    @Test func snapsTheNearestEdge() {
        #expect(snapOffset([100, 200], to: [98, 203], within: 6)! == (-2, 98))
        #expect(snapOffset([100, 200], to: [96, 202], within: 6)! == (2, 202)) // the nearer of the two edges' targets
        #expect(snapOffset([100], to: [107, 300], within: 6) == nil)
    }
}

@Suite struct Cuts {
    // 1–9 s kept, split at 3 and 6 and the middle part cut: 1–3 and 6–9 play.
    func cut() -> Edits {
        var e = Edits(trim: Trim(start: 1, end: 9))
        let split = e.split(at: 3) && e.split(at: 6)
        #expect(split)
        e.removeSegment(1)
        return e
    }
    @Test func splitsAndRemovesSegments() {
        let e = cut()
        #expect(e.keptSegments == [Trim(start: 1, end: 3), Trim(start: 6, end: 9)])
        #expect(outputDuration(e.keptSegments) == 5)
        var f = e
        let inCut = f.split(at: 4.5)
        #expect(!inCut)                                // inside the cut: nothing to split
        f.removeSegment(0)                             // cutting the first part moves the trim in
        #expect(f.trim == Trim(start: 6, end: 9) && f.segments == nil)
        f.removeSegment(0)                             // the last part can't go
        #expect(f.keptSegments == [Trim(start: 6, end: 9)])
    }
    @Test func mapsOutputTimeToRecordingTimeAndBack() {
        let s = cut().keptSegments
        #expect(outputToSource(s, 0) == 1 && outputToSource(s, 1.5) == 2.5)
        #expect(outputToSource(s, 2) == 6 && outputToSource(s, 4) == 8 && outputToSource(s, 99) == 9)
        #expect(sourceToOutput(s, 2.5) == 1.5 && sourceToOutput(s, 7) == 3)
        #expect(sourceToOutput(s, 4.5) == 2 && sourceToOutput(s, 0) == 0) // in the cut: where it carries on; before the trim: 0
        for t in stride(from: 0.0, to: 5, by: 0.25) { #expect(abs(sourceToOutput(s, outputToSource(s, t)) - t) < 1e-9) }
    }
    @Test func trimHandlesMoveTheOuterSegments() {
        var e = cut()
        e.trim = Trim(start: 0.5, end: 8)
        #expect(e.keptSegments == [Trim(start: 0.5, end: 3), Trim(start: 6, end: 8)])
        e.trim.start = 4 // past the first part: it's gone, the second starts at the new trim
        #expect(e.keptSegments == [Trim(start: 4, end: 8)])
    }
    @Test func silencesOnePartOfASourceAndBringsItBack() {
        var e = cut()
        e.toggleSilence(.mic, Trim(start: 1, end: 3))
        e.toggleSilence(.mic, Trim(start: 6, end: 7))
        e.toggleSilence(.system, Trim(start: 6, end: 9))
        #expect(e.silencedRanges(.mic) == [Trim(start: 1, end: 3), Trim(start: 6, end: 7)])
        e.toggleSilence(.mic, Trim(start: 1, end: 2))          // already silent there: back on for just that bit
        #expect(e.silencedRanges(.mic) == [Trim(start: 2, end: 3), Trim(start: 6, end: 7)])
        e.toggleSilence(.mic, Trim(start: 2.5, end: 6.5))      // partly silent: silence all of it, joining up
        #expect(e.silencedRanges(.mic) == [Trim(start: 2, end: 7)])
        #expect(e.silencedRanges(.system) == [Trim(start: 6, end: 9)])
    }
    @Test func splitsEveryLaneAndJoinsBackForRendering() {
        var e = Edits(trim: Trim(start: 0, end: 10), zooms: [Zoom(start: 1, end: 5, scale: 2), Zoom(start: 7, end: 8, scale: 1.5)],
                      callouts: [Callout(text: "Hi", start: 2, end: 4, x: 0, y: 0)])
        e.allAnnotations = [Annotation(kind: .arrow, start: 6, end: 9, x: 0, y: 0, w: 0.1, h: 0.1, fade: 0.3)]
        e.split(at: 3)
        #expect(e.zooms.map { [$0.start, $0.end] } == [[1, 3], [3, 5], [7, 8]] && e.zooms[1].scale == 2)
        #expect(e.callouts.map(\.end) == [3, 4] && e.allAnnotations.count == 1)       // the arrow doesn't span 3 s
        // Untouched, the pieces render as one: no ease out and back in at the split.
        #expect(joiningTouching(e.zooms) == [Zoom(start: 1, end: 5, scale: 2), Zoom(start: 7, end: 8, scale: 1.5)])
        #expect(zoomAt(joiningTouching(e.zooms), 3) == 2)
        // Changed, they're separate: deleting one leaves the other, a different scale keeps them apart.
        e.zooms.remove(at: 0)
        #expect(e.zooms.first == Zoom(start: 3, end: 5, scale: 2))
        var two = e; two.split(at: 4); two.zooms[1].scale = 3
        #expect(joiningTouching(two.zooms).count == 3)
    }
    @Test func timelineDrawsSplitPiecesApartAndUnsplitItemsWhole() {
        var e = Edits(trim: Trim(start: 0, end: 10), zooms: [Zoom(start: 1, end: 5, scale: 2)])
        e.split(at: 3)
        e.zooms.append(Zoom(start: 2, end: 4, scale: 3))   // added across the split afterwards: not split
        #expect(touchesNext(e.zooms, 0) && !touchesNext(e.zooms, 1) && !touchesNext(e.zooms, 2))
        // Sound is drawn a block per kept segment, short of the next one at each split.
        let b = blocks([Trim(start: 0, end: 10)], in: e.keptSegments)
        #expect(b.map(\.piece) == [Trim(start: 0, end: 3), Trim(start: 3, end: 10)] && b.map(\.gap) == [true, false])
        #expect(blocks([Trim(start: 4, end: 6)], in: e.keptSegments).map(\.gap) == [false])
    }
    @Test func silencesVolumePointsWithShortFades() {
        let flat = silencing([(t: 0, gain: 0.8)], [Trim(start: 2, end: 3)])
        func at(_ t: Double) -> Double { flat.first { abs($0.t - t) < 1e-9 }!.gain }
        #expect(at(0) == 0.8 && abs(at(1.99) - 0.8) < 1e-9 && at(2) == 0 && at(3) == 0 && abs(at(3.01) - 0.8) < 1e-9)
        let ramp = silencing([(t: 0, gain: 0), (t: 10, gain: 1)], [Trim(start: 4, end: 5)])
        #expect(abs(ramp.first { abs($0.t - 3.99) < 1e-9 }!.gain - 0.399) < 1e-9) // follows the original ramp up to the fade
        #expect(silencing([(t: 0, gain: 1)], []).count == 1)
    }
    @Test func olderEditsAreOneSegment() throws {
        let e = try JSONDecoder().decode(Edits.self, from: Data(##"{"trim":{"start":0.5,"end":3},"crop":{"x":0,"y":0,"w":1,"h":1},"zooms":[],"padding":0.06,"background":"#1e1b4b","cursorHighlight":true,"callouts":[]}"##.utf8))
        #expect(e.keptSegments == [Trim(start: 0.5, end: 3)])
    }
}

@Suite struct Camera {
    @Test func keepsTheZoomedViewInsideTheFrame() {
        let path = cameraPath([CursorSample(t: 0, x: 0.99, y: 0.01, down: false)], edits { $0.zooms = [Zoom(start: 0, end: 20, scale: 2)] }, duration: 20)
        let mid = cameraAt(path, 5)
        #expect(mid.z == 2 && abs(mid.x - 0.75) < 1e-6 && abs(mid.y - 0.25) < 1e-6)
    }
    @Test func pinnedZoomLandsOnItsFocus() {
        let e = edits { $0.zooms = [Zoom(start: 1, end: 5, scale: 2, focus: Point(x: 0.3, y: 0.6))] }
        let path = cameraPath([CursorSample(t: 0, x: 0.9, y: 0.1, down: false)], e, duration: 6)
        let mid = cameraAt(path, 3)
        #expect(mid.z == 2 && abs(mid.x - 0.3) < 1e-6 && abs(mid.y - 0.6) < 1e-6)
        let ramp = cameraAt(path, 1.3)
        #expect(ramp.x > 0.3 && ramp.x < 0.9)
    }
    @Test func followsTheCursorSmoothlyInCropCoordinates() {
        // Held at 4× so the edge clamp doesn't pin the camera; the cursor crosses the right half of the crop.
        let e = edits { $0.crop = NRect(x: 0.5, y: 0, w: 0.5, h: 1); $0.zooms = [Zoom(start: -5, end: 10, scale: 4)] }
        let path = cameraPath([CursorSample(t: 0, x: 0.75, y: 0.5, down: false), CursorSample(t: 1, x: 1, y: 0.5, down: false)], e, duration: 2)
        let xs = path.prefix(16).map(\.x)
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 }) // monotone, no overshoot
        #expect(xs[15] < 1) // lags behind the raw cursor
        #expect(xs[2] - xs[1] < xs[8] - xs[7]) // accelerates into the pan
    }
}

@Suite struct Output {
    @Test func capsWidthPadsEvenlyAndKeepsEvenDimensions() {
        let s = outputSize(width: 2880, height: 1800, edits { $0.padding = 0.1 })
        #expect(s.width <= 1920 && s.contentW % 2 == 0 && s.contentH % 2 == 0)
        #expect(s.width == s.contentW + 2 * s.x)
        #expect(outputSize(width: 640, height: 400, edits()) == OutputSize(contentW: 640, contentH: 400, x: 38, y: 38, width: 716, height: 476))
    }
    @Test func resolutionPresetsCapTheLongSideButNeverUpscale() {
        let flat = edits { $0.padding = 0 }
        func size(_ w: Int, _ h: Int, _ e: Edits, _ r: ExportResolution) -> [Int] {
            let s = outputSize(width: w, height: h, e, maxLongSide: r.longSide)
            return [s.width, s.height]
        }
        #expect(size(3840, 2160, flat, .p720) == [1280, 720])
        #expect(size(3840, 2160, flat, .p1080) == [1920, 1080])
        #expect(size(3840, 2160, flat, .p1440) == [2560, 1440])
        #expect(size(3840, 2160, flat, .p2160) == [3840, 2160])
        #expect(size(1280, 800, flat, .p2160) == [1280, 800])        // smaller recording: kept as is
        #expect(size(1080, 1920, flat, .p720) == [720, 1280])        // portrait: the long side is the height
        // Fixed aspect ratios: the frame's long side follows the preset.
        #expect(size(3840, 2160, edits { $0.aspect = "9:16"; $0.padding = 0 }, .p1080) == [1080, 1920])
        #expect(size(3840, 2160, edits { $0.aspect = "1:1"; $0.padding = 0 }, .p720) == [1280, 1280])
        #expect(size(1000, 1000, edits { $0.aspect = "16:9"; $0.padding = 0 }, .p2160) == [1000, 562]) // never upscaled
        // With padding the padded frame fits the preset, and padding stays even on both sides.
        let padded = outputSize(width: 3840, height: 2160, edits(), maxLongSide: ExportResolution.p1440.longSide)
        #expect(padded.width <= 2560 && padded.width == padded.contentW + 2 * padded.x && padded.contentW % 2 == 0)
        // The preview size is the old 1920 cap.
        #expect(outputSize(width: 3840, height: 2160, flat) == outputSize(width: 3840, height: 2160, flat, maxLongSide: 1920))

        #expect(exportBitrate(width: 1920, height: 1080, fps: 30, .high, hevc: false) == Int(1920.0 * 1080 * 30 * 0.14))
        #expect(exportBitrate(width: 1920, height: 1080, fps: 30, .standard, hevc: false) < exportBitrate(width: 1920, height: 1080, fps: 30, .maximum, hevc: false))
        #expect(exportBitrate(width: 1920, height: 1080, fps: 30, .high, hevc: true) < exportBitrate(width: 1920, height: 1080, fps: 30, .high, hevc: false))
        #expect(exportBitrate(width: 1920, height: 1080, fps: 120, .high, hevc: false) == exportBitrate(width: 1920, height: 1080, fps: 60, .high, hevc: false))
    }
    @Test func fitsTheRecordingInsideAChosenAspectRatio() {
        // 16:10 recording into a vertical 9:16 frame: full width minus padding, centred vertically.
        let v = outputSize(width: 2880, height: 1800, edits { $0.aspect = "9:16"; $0.padding = 0.05 })
        #expect(v.height == 1920 && v.width == 1080)
        #expect(v.contentW == 972 && v.x == 54)                // 5% of the short side on each side
        #expect(abs(Double(v.contentW) / Double(v.contentH) - 1.6) < 0.01) // recording keeps its shape
        #expect(v.y == (v.height - v.contentH) / 2)
        let sq = outputSize(width: 1000, height: 1000, edits { $0.aspect = "16:9"; $0.padding = 0 })
        #expect(sq.width == 1000 && sq.height == 562 && sq.contentH == 562 && sq.x == (1000 - sq.contentW) / 2)
        #expect(validateEdits(edits { $0.aspect = "7:3" }, duration: 20).count == 1)
    }
    @Test func placesTheWebcamBubbleAndShrinksItWhileZoomed() {
        let s = OutputSize(contentW: 1600, contentH: 1000, x: 160, y: 40, width: 1920, height: 1080)
        var c = CameraStyle()
        let r = cameraRect(s, c, zoom: 1)
        #expect(abs(r.d - 0.24 * 1080) < 1e-9)
        #expect(abs(r.x + r.d - (1920 - 0.04 * 1080)) < 1e-9 && abs(r.y + r.d - (1080 - 0.04 * 1080)) < 1e-9) // bottom-right, inset
        #expect(abs(cameraRect(s, c, zoom: 1.8).d - r.d * 0.65) < 1e-9) // fully zoomed: 35% smaller
        c.shrinkWhenZoomed = false
        #expect(cameraRect(s, c, zoom: 1.8).d == r.d)
        c.corner = .topLeft
        #expect(cameraRect(s, c, zoom: 1).x == 0.04 * 1080 && cameraRect(s, c, zoom: 1).y == 0.04 * 1080)
        c.size = 0.9
        #expect(validateEdits(edits { $0.camera = c }, duration: 20) == ["Webcam size must be between 10% and 50%."])
    }
    @Test func placesADraggedBubbleAnywhereButKeepsItOnTheCanvas() {
        let s = OutputSize(contentW: 1600, contentH: 1000, x: 160, y: 40, width: 1920, height: 1080)
        var c = CameraStyle()
        let d = 0.24 * 1080
        c.center = Point(x: 0.5, y: 0.5)
        let mid = cameraRect(s, c, zoom: 1)
        #expect(abs(mid.x - (960 - d / 2)) < 1e-9 && abs(mid.y - (540 - d / 2)) < 1e-9)
        // Shrinking while zoomed keeps the centre where it was.
        let small = cameraRect(s, c, zoom: 1.8)
        #expect(abs(small.x + small.d / 2 - 960) < 1e-9 && abs(small.y + small.d / 2 - 540) < 1e-9)
        // Dragged past the edges: stops flush with the canvas.
        c.center = Point(x: 0, y: 0)
        #expect(cameraRect(s, c, zoom: 1).x == 0 && cameraRect(s, c, zoom: 1).y == 0)
        c.center = Point(x: 1, y: 1)
        let far = cameraRect(s, c, zoom: 1)
        #expect(abs(far.x - (1920 - d)) < 1e-9 && abs(far.y - (1080 - d)) < 1e-9)
        // Dropping: the top-left corner maps back to a centre, clamped the same way.
        let back = cameraCenter(s, c, topLeft: 100, 200)
        #expect(abs(back.x - (100 + d / 2) / 1920) < 1e-9 && abs(back.y - (200 + d / 2) / 1080) < 1e-9)
        let off = cameraCenter(s, c, topLeft: -500, 5000)
        #expect(abs(off.x - d / 2 / 1920) < 1e-9 && abs(off.y - (1080 - d / 2) / 1080) < 1e-9)

        // Corner presets: margin 0 sits flush; nil keeps the old 4%.
        c.center = nil
        c.margin = 0
        let flush = cameraRect(s, c, zoom: 1)
        #expect(abs(flush.x - (1920 - d)) < 1e-9 && abs(flush.y - (1080 - d)) < 1e-9)
        c.margin = 0.5
        #expect(validateEdits(edits { $0.camera = c }, duration: 20) == ["Webcam margin must be between 0% and 15%."])
        c.margin = nil
        c.center = Point(x: 1.5, y: 0)
        #expect(validateEdits(edits { $0.camera = c }, duration: 20) == ["Webcam position is off-canvas."])
    }
    @Test func bubbleRoundnessGoesFromSquareToCircle() {
        var c = CameraStyle()
        #expect(bubbleCornerRadius(diameter: 200, c) == 100)  // default circle
        c.roundness = 0
        #expect(bubbleCornerRadius(diameter: 200, c) == 0)    // square
        c.roundness = 1
        #expect(bubbleCornerRadius(diameter: 200, c) == 100)  // circle
        c.roundness = 0.5
        #expect(bubbleCornerRadius(diameter: 200, c) == 50)
        c.roundness = 2
        #expect(bubbleCornerRadius(diameter: 200, c) == 100)  // never more than a circle
        #expect(validateEdits(edits { $0.camera = c }, duration: 20) == ["Webcam roundness must be between 0% and 100%."])
        // Older edits chose circle or rounded; rounded was a 20%-of-size corner, i.e. 40% roundness.
        let rounded = try? JSONDecoder().decode(CameraStyle.self, from: Data(#"{"visible":true,"shape":"rounded","size":0.24,"corner":"bottomRight","mirror":true,"shrinkWhenZoomed":true}"#.utf8))
        #expect(rounded?.roundness == nil && rounded?.center == nil && rounded?.margin == nil)
        #expect(abs((rounded.map { bubbleCornerRadius(diameter: 200, $0) } ?? 0) - 40) < 1e-9)
    }
    @Test func cornerRadiusIsAutomaticOrExplicitAndMatchesWindows() {
        let s = OutputSize(contentW: 1600, contentH: 1000, x: 160, y: 40, width: 1920, height: 1080)
        #expect(abs(cornerRadiusPx(s, edits()) - 18) < 1e-9)                                  // padded: gentle default
        #expect(cornerRadiusPx(OutputSize(contentW: 1600, contentH: 1000, x: 0, y: 0, width: 1600, height: 1000), edits()) == 0)
        #expect(cornerRadiusPx(s, edits { $0.cornerRadius = 0.05 }) == 50)                    // 5% of the shorter side
        // A 2× window recording 1400 px tall: 26 pt = 52 px.
        #expect(abs(windowCornerFraction(width: 1800, height: 1400, crop: .full, pointScale: 2) - 52.0 / 1400) < 1e-9)
        #expect(validateEdits(edits { $0.cornerRadius = 0.5 }, duration: 20) == ["Corner radius must be between 0% and 15%."])
    }
    @Test func shadowsDefaultToTheOriginalLookAndTurnOff() {
        let s = OutputSize(contentW: 1600, contentH: 1000, x: 160, y: 40, width: 1920, height: 1080)
        let d = frameShadow(s, edits())!                                                      // nil settings: the look from before
        #expect(abs(d.alpha - 0.45) < 1e-9 && abs(d.radius - 25) < 1e-9 && abs(d.offset - 12) < 1e-9)
        #expect(frameShadow(s, edits { $0.shadow = 0 }) == nil)
        #expect(frameShadow(OutputSize(contentW: 1600, contentH: 1000, x: 0, y: 0, width: 1600, height: 1000), edits()) == nil) // nowhere to show
        #expect(frameShadow(s, edits { $0.shadow = 1 })!.alpha > d.alpha)
        #expect(frameShadow(s, edits { $0.shadowSoftness = 1 })!.radius > d.radius)
        #expect(frameShadow(s, edits { $0.shadowSoftness = 0 })!.radius < d.radius)

        var c = CameraStyle()
        let b = bubbleShadow(diameter: 200, c)!
        #expect(abs(b.alpha - 0.5) < 1e-9 && abs(b.radius - 10) < 1e-9 && abs(b.offset - 6) < 1e-9)
        c.shadow = 0
        #expect(bubbleShadow(diameter: 200, c) == nil)

        #expect(validateEdits(edits { $0.shadow = 1.5; $0.shadowSoftness = -1; $0.camera = c; $0.camera?.shadow = .nan }, duration: 20) == [
            "Shadow must be between 0% and 100%.", "Shadow softness must be between 0% and 100%.", "Webcam shadow must be between 0% and 100%."])
        // Webcam styles saved before the shadow setting existed still load.
        let old = try? JSONDecoder().decode(CameraStyle.self, from: Data(#"{"visible":true,"shape":"circle","size":0.24,"corner":"bottomRight","mirror":true,"shrinkWhenZoomed":true}"#.utf8))
        #expect(old != nil && old?.shadow == nil)
    }
    @Test func gradientsRunCornerToCornerLikeCSS() {
        func ends(_ angle: Double) -> [Double] {
            let e = gradientEnds(BackgroundGradient(from: "#000000", to: "#ffffff", angle: angle), width: 400, height: 200)
            return [e.start.x, e.start.y, e.end.x, e.end.y].map { ($0 * 1000).rounded() / 1000 }
        }
        #expect(ends(90) == [0, 100, 400, 100])     // left → right
        #expect(ends(180) == [200, 0, 200, 200])    // top → bottom
        #expect(ends(0) == [200, 200, 200, 0])      // bottom → top
        // 135°: the line is long enough that the top-left and bottom-right corners get exactly the end colours.
        let d = ends(135)
        #expect(abs(d[0] - 50) < 1e-3 && abs(d[1] + 50) < 1e-3 && abs(d[2] - 350) < 1e-3 && abs(d[3] - 250) < 1e-3)

        #expect(backgroundBlurRadius(edits(), short: 1000) == 0)
        #expect(backgroundBlurRadius(edits { $0.backgroundBlur = 1 }, short: 1000) == 50)
        #expect(validateEdits(edits { $0.gradient = BackgroundGradient(from: "red", to: "#ffffff", angle: 400); $0.backgroundBlur = 2 }, duration: 20) == [
            "Gradient colours must be #rrggbb.", "Gradient angle must be between 0° and 360°.", "Background blur must be between 0% and 100%."])
        #expect(BackgroundGradient.presets.allSatisfy { g in validateEdits(edits { $0.gradient = g }, duration: 20).isEmpty })
        // New recordings start on the graphite gradient with the click ripple.
        let fresh = defaultEdits(duration: 5, cursor: [])
        #expect(fresh.gradient == BackgroundGradient(from: "#2b2d31", to: "#4a4d55", angle: 180) && fresh.backgroundImage == nil)
        #expect(fresh.clickEffect == .ripple)
    }
    @Test func gifFramesAndSizeFollowTheSettings() {
        let canvas = OutputSize(contentW: 1600, contentH: 1000, x: 160, y: 40, width: 1920, height: 1080)
        let s = gifSize(canvas, GIFOptions(width: 640))
        #expect(s.width == 640 && s.height == 360)
        let small = OutputSize(contentW: 600, contentH: 400, x: 0, y: 0, width: 600, height: 400)
        let t = gifSize(small, GIFOptions(width: 1080))
        #expect(t.width == 600 && t.height == 400)                               // never scaled up
        #expect(gifFrameCount(seconds: 3, GIFOptions(fps: 10)) == 30)
        #expect(gifFrameCount(seconds: 3, GIFOptions(fps: 15)) == 45)
        #expect(gifFrameCount(seconds: 3.01, GIFOptions(fps: 10)) == 31)          // a partial frame still shows
        #expect(gifFrameCount(seconds: 0, GIFOptions()) == 1)
        let short = gifEstimatedBytes(canvas, seconds: 5, GIFOptions()), long = gifEstimatedBytes(canvas, seconds: 10, GIFOptions())
        #expect(short > 0 && long > short && gifEstimatedBytes(canvas, seconds: 5, GIFOptions(width: 1080)) > short)
    }
    @Test func exportNamesAndEstimates() {
        #expect(exportFileName("  Q3 onboarding: part 1/2 ") == "Q3 onboarding- part 1-2")
        #expect(exportFileName("..hidden") == "hidden" && exportFileName("   ") == "Recording")
        let taken: Set = ["Demo", "Demo 2"]
        #expect(keepBothName("Demo") { taken.contains($0) } == "Demo 3")
        #expect(keepBothName("New") { taken.contains($0) } == "New")
        // 1080p High H.264 for 10 s: the video bitrate plus 160 kbps of audio.
        let mp4 = videoEstimatedBytes(width: 1920, height: 1080, fps: 30, seconds: 10, .high, hevc: false)
        #expect(mp4 == (exportBitrate(width: 1920, height: 1080, fps: 30, .high, hevc: false) + 160_000) * 10 / 8)
        #expect(videoEstimatedBytes(width: 1920, height: 1080, fps: 30, seconds: 10, .high, hevc: true) < mp4)
    }
    @Test func annotationsFadeAndValidate() {
        let a = Annotation(kind: .arrow, start: 2, end: 6, x: 0.2, y: 0.5, w: 0.6, h: 0, fade: 0.5)
        #expect(annotationOpacity(a, at: 1.9) == 0 && annotationOpacity(a, at: 6.1) == 0)
        #expect(abs(annotationOpacity(a, at: 2.25) - 0.5) < 1e-9)      // halfway through the fade-in
        #expect(annotationOpacity(a, at: 4) == 1)
        #expect(abs(annotationOpacity(a, at: 5.75) - 0.5) < 1e-9)
        var sharp = a
        sharp.fade = nil
        #expect(annotationOpacity(sharp, at: 2) == 1 && annotationOpacity(sharp, at: 6) == 1)
        var short = a
        short.end = 2.4                                                  // shorter than two fades: ramps meet in the middle
        #expect(abs(annotationOpacity(short, at: 2.2) - 1) < 1e-9)

        // Empty lists are stored as nil, so edits without annotations encode exactly as before.
        var e = edits()
        e.allAnnotations = [a]
        #expect(e.annotations?.count == 1)
        e.allAnnotations = []
        #expect(e.annotations == nil)

        #expect(validateEdits(edits { $0.allAnnotations = [a] }, duration: 20).isEmpty)
        var bad = Annotation(kind: .rectangle, start: 3, end: 1, x: 2, y: 0, w: 0.2, h: 0.2, color: "red", stroke: 1, fade: 5)
        #expect(validateEdits(edits { $0.allAnnotations = [bad] }, duration: 20) == [
            "Annotation 1: end must be after start.", "Annotation 1: position is off-canvas.", "Annotation 1: colour must be #rrggbb.",
            "Annotation 1: line width is out of range.", "Annotation 1: fade must be between 0 and 2 seconds."])
        bad = Annotation(kind: .image, start: 1, end: 3, x: 0.1, y: 0.1, w: 0, h: 0.2, image: "/x.gif")
        #expect(validateEdits(edits { $0.allAnnotations = [bad] }, duration: 20) == [
            "Annotation 1: it's too small to see.", "Annotation 1: pick a HEIC, JPEG, PNG, TIFF or WebP image."])
        // An arrow can point any way, so negative sizes are fine.
        #expect(validateEdits(edits { $0.allAnnotations = [Annotation(kind: .arrow, start: 1, end: 3, x: 0.8, y: 0.8, w: -0.5, h: -0.3)] }, duration: 20).isEmpty)
    }
    @Test func extraAudioFadesDucksAndValidates() {
        var m = AudioTrack(path: "/a/song.m4a", fileDuration: 30, at: 2, from: 5, length: 10, volume: 0.8, fadeIn: 1, fadeOut: 2)
        #expect(musicGain(m, at: 1.9) == 0 && musicGain(m, at: 12.1) == 0)        // only while it plays
        #expect(abs(musicGain(m, at: 2.5) - 0.4) < 1e-9)                            // halfway through the fade-in
        #expect(abs(musicGain(m, at: 6) - 0.8) < 1e-9)
        #expect(abs(musicGain(m, at: 11) - 0.4) < 1e-9)                             // halfway through the fade-out
        // Ducking only applies when asked, dips to a quarter inside speech, and ramps either side.
        let voice: [ClosedRange<Double>] = [5...7]
        #expect(abs(musicGain(m, at: 6, voice: voice) - 0.8) < 1e-9)
        m.duck = true
        #expect(abs(musicGain(m, at: 6, voice: voice) - 0.8 * AudioTrack.duckLevel) < 1e-9)
        #expect(abs(musicGain(m, at: 4, voice: voice) - 0.8) < 1e-9)                // well before the voice
        let ramp = musicGain(m, at: 5 - AudioTrack.duckRamp / 2, voice: voice)
        #expect(ramp < 0.8 && ramp > 0.8 * AudioTrack.duckLevel)
        // The bend points cover the fades and the dip, and straight lines between them match the curve.
        let pts = musicVolumePoints(m, voice: voice)
        #expect(pts.first?.t == 2 && pts.last?.t == 12 && pts.contains { $0.t == 5 } && pts.contains { $0.t == 7 + AudioTrack.duckRamp })
        #expect(pts.allSatisfy { abs($0.gain - musicGain(m, at: $0.t, voice: voice)) < 1e-12 })

        // Speech: loud windows become ranges; short gaps are bridged and blips dropped.
        let w = 0.1
        let levels: [Double] = [0, 0.1, 0.1, 0.1, 0, 0, 0.1, 0.1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.1, 0, 0]
        let r = voiceRanges(levels: levels, window: w)
        #expect(r.count == 1)                                                       // the blip at 1.7 s is dropped
        #expect(abs(r[0].lowerBound - 0.1) < 1e-9 && abs(r[0].upperBound - 0.8) < 1e-9) // 0.1–0.4 and 0.6–0.8 joined

        #expect(validateEdits(edits { $0.audio = m }, duration: 20).isEmpty)
        var bad = m
        bad.path = "/a/song.ogg"; bad.length = 40; bad.volume = 2; bad.fadeIn = -1
        #expect(validateEdits(edits { $0.audio = bad }, duration: 20) == [
            "Audio must be M4A, MP3, WAV, AIFF, CAF or AAC.", "Audio: its start and length must stay within the file.",
            "Audio volume must be between 0% and 100%.", "Audio fades must be between 0 and 10 seconds."])
    }
    @Test func validationCatchesEveryBadField() {
        let bad = Edits(trim: Trim(start: 5, end: 5.1), crop: NRect(x: 0.9, y: 0, w: 0.5, h: 1),
                        zooms: [Zoom(start: 2, end: 1, scale: 9, focus: Point(x: 2, y: 0))], padding: 1, background: "red",
                        backgroundImage: "/x.gif", callouts: [Callout(text: " ", start: 3, end: 1, x: 2, y: 0)])
        #expect(validateEdits(bad, duration: 10).count == 11)
        #expect(validateEdits(edits(), duration: 20).isEmpty)
    }
    @Test func calloutTextStopsAtItsLimit() {
        // A realistic instruction that used to be accepted while typing, then block the export.
        let typed = "Open Settings › Organisation › Members & Roles › Invite people, then paste the list of email addresses from the spreadsheet"
        #expect(typed.count == 123 && Callout.limited(typed).count == Callout.maxText && Callout.limited("Hi") == "Hi")
        let ok = edits { $0.callouts = [Callout(text: Callout.limited(typed), start: 1, end: 2, x: 0, y: 0)] }
        #expect(validateEdits(ok, duration: 20).isEmpty)
        let long = edits { $0.callouts = [Callout(text: typed, start: 1, end: 2, x: 0, y: 0)] }
        #expect(validateEdits(long, duration: 20) == ["Callout 1: text must be 1–120 characters."])
    }
    @Test func readsEditsSavedByTheTauriVersion() throws {
        let json = ##"{"trim":{"start":0,"end":3.5},"crop":{"x":0,"y":0,"w":1,"h":1},"zooms":[{"start":1,"end":3,"scale":1.8,"focus":null}],"padding":0.06,"background":"#1e1b4b","cursorHighlight":true,"callouts":[]}"##
        let e = try JSONDecoder().decode(Edits.self, from: Data(json.utf8))
        #expect(e.zooms.first?.focus == nil && e.backgroundImage == nil && e.trim.end == 3.5)
        #expect(e.gradient == nil && e.backgroundBlur == nil)
    }
    @Test func summaryListsMomentsWithinTheTrim() {
        let md = summaryMarkdown(title: "Demo", createdAt: Date(timeIntervalSince1970: 0), edits: edits { $0.trim = Trim(start: 1, end: 15); $0.zooms = autoZooms(cursor, duration: 20) },
                                 video: "Demo 1.mp4", poster: "Demo 1.jpg", transcript: "")
        #expect(md.contains("# Demo") && md.contains("[Demo 1.mp4](Demo%201.mp4)"))
        #expect(md.contains("- 0:00 — Zoom 1.8×") && md.contains("_No transcript._"))
    }
}

@Suite struct Shortcuts {
    @Test func parsesInAnyOrderAndWritesOneForm() {
        let s = Shortcut("Cmd + Option+CTRL+R")
        #expect(s?.text == "ctrl+opt+cmd+r" && s?.symbol == "⌃⌥⌘R" && s?.keyCode == 15)
        #expect(Shortcut("space")?.symbol == "Space" && Shortcut("shift+delete")?.symbol == "⇧⌫")
        #expect(Shortcut("cmd+,")?.key == "," && Shortcut("cmd+,")?.keyCode == 43)
        #expect(Shortcut("hyper+r") == nil && Shortcut("cmd+") == nil && Shortcut("cmd+ab") == nil && Shortcut("") == nil)
        #expect(Shortcut("cmd+Ž")?.symbol == "⌘Ž" && Shortcut("cmd+ž")?.keyCode == nil)
        #expect(Shortcut(keyCode: 49, modifiers: [.shift]) == Shortcut("shift+space"))
        for (key, _) in Shortcut.keyCodes { #expect(Shortcut(Shortcut(key: key, modifiers: [.control, .command])!.text)?.key == key) }
    }
    @Test func storageRoundTrips() {
        var map = ShortcutMap.defaults
        map[.play] = Shortcut("shift+p")
        map[.addZoom] = nil
        let back = ShortcutMap(stored: map.stored)
        #expect(back == map && back[.addZoom] == nil && back[.play]?.text == "shift+p")
        #expect(map.stored["addZoom"] == "")
        // Missing or unreadable entries fall back to the default, so older settings keep working.
        let partial = ShortcutMap(stored: ["play": "nonsense+x", "setIn": "j"])
        #expect(partial[.play] == ShortcutMap.defaults[.play] && partial[.setIn]?.key == "j" && partial[.newRecording]?.text == "ctrl+opt+cmd+r")
    }
    @Test func findsEditorActionsAndConflicts() {
        var map = ShortcutMap.defaults
        #expect(map.editorAction(for: Shortcut("space")!) == .play && map.editorAction(for: Shortcut("ctrl+opt+cmd+r")!) == nil)
        #expect(ShortcutAction.allCases.allSatisfy { map.conflicts(for: $0).isEmpty })
        map[.setOut] = Shortcut("i")
        #expect(map.conflicts(for: .setIn) == ["Also set for Set Trim End."])
        map[.newRecording] = Shortcut("cmd+n")
        #expect(map.conflicts(for: .newRecording).count == 2)
        #expect(ShortcutMap.problem(Shortcut("r")!, for: .newRecording) != nil && ShortcutMap.problem(Shortcut("shift+r")!, for: .stopRecording) != nil)
        #expect(ShortcutMap.problem(Shortcut("r")!, for: .play) == nil && ShortcutMap.problem(Shortcut("escape")!, for: .play) != nil)
    }
}

@Suite struct RecordingSound {
    @Test func volumesAreOptionalAndValidated() throws {
        let e = edits()
        #expect(e.micVolume == nil && e.systemVolume == nil)
        let back = try JSONDecoder().decode(Edits.self, from: JSONEncoder().encode(e))
        #expect(back == e)
        #expect(validateEdits(edits { $0.micVolume = 0; $0.systemVolume = 1 }, duration: 20).isEmpty)
        #expect(validateEdits(edits { $0.micVolume = 1.5; $0.systemVolume = -0.1 }, duration: 20).count == 2)
        #expect(validateEdits(edits { $0.systemVolume = .nan }, duration: 20).count == 1)
    }
}

@Suite struct Undo {
    @Test func undoesBackToTheStartAndRedoesToTheEnd() {
        var h = EditHistory(), e = Edits(trim: Trim(start: 0, end: 10))
        let original = e
        func change(_ at: Double, drag: Edits? = nil, _ f: (inout Edits) -> Void) { let before = e; f(&e); h.record(before, at: at, drag: drag) }
        change(0) { $0.zooms.append(Zoom(start: 1, end: 3, scale: 2)) }
        change(5) { $0.split(at: 5) }
        // A drag, however long and with pauses, is one step.
        let origin = e
        for (i, t) in [10.0, 11, 13, 16].enumerated() { change(t, drag: origin) { $0.zooms[0].start = 1 + Double(i + 1) * 0.1 } }
        // Slider steps close together are one step; a pause starts another.
        change(20) { $0.padding = 0.1 }
        change(20.2) { $0.padding = 0.12 }
        change(25) { $0.padding = 0.2 }
        let last = e
        #expect(h.undoStack.count == 5)
        var undone: [Edits] = []
        while let u = h.undo(e) { e = u; undone.append(u) }
        #expect(e == original && undone[0].padding == 0.12 && undone[1].padding == 0.06 && undone[2].zooms[0].start == 1)
        while let r = h.redo(e) { e = r }
        #expect(e == last)
        // A new change after undoing drops what could be redone.
        e = h.undo(e)!
        change(30) { $0.background = "#000000" }
        #expect(!h.canRedo && h.canUndo)
    }
}

@Suite struct Gallery {
    struct Item { let name: String, created: Date, edited: Date }
    // Just after midnight on Wednesday 7 October 2026, UTC.
    let now = ISO8601DateFormatter().date(from: "2026-10-07T00:30:00Z")!
    func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    func calendar(firstWeekday: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = firstWeekday
        return c
    }
    var items: [Item] {
        [("late last night", "2026-10-06T23:50:00Z"), ("just now", "2026-10-07T00:10:00Z"), ("monday", "2026-10-05T10:00:00Z"),
         ("sunday", "2026-10-04T12:00:00Z"), ("last month", "2026-09-01T09:00:00Z"), ("edited a", "2026-08-01T09:00:00Z"),
         ("edited b", "2026-08-02T09:00:00Z")].map { Item(name: $0.0, created: at($0.1), edited: at($0.1)) }
            .map { $0.name.hasPrefix("edited") ? Item(name: $0.name, created: $0.created, edited: at($0.name == "edited a" ? "2026-10-07T00:20:00Z" : "2026-10-07T00:15:00Z")) : $0 }
    }
    func names(_ firstWeekday: Int, recent: Int = 2) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: gallerySections(items, created: \.created, edited: \.edited, now: now,
                                                         calendar: calendar(firstWeekday: firstWeekday), recent: recent).map { ($0.section.rawValue, $0.items.map(\.name)) })
    }
    @Test func sortsIntoSectionsAcrossMidnightAndTheStartOfTheWeek() {
        let monday = names(2)
        #expect(monday["Recently edited"] == ["edited a", "edited b"])
        #expect(monday["Today"] == ["just now"] && monday["Yesterday"] == ["late last night"])
        #expect(monday["This week"] == ["monday"])
        #expect(monday["Older"] == ["sunday", "last month"])
        // With weeks starting on Sunday, Sunday is this week.
        #expect(names(1)["This week"] == ["monday", "sunday"] && names(1)["Older"] == ["last month"])
    }
    @Test func recentlyEditedTakesFiveAndEmptySectionsAreLeftOut() {
        let all = gallerySections(items, created: \.created, edited: \.edited, now: now, calendar: calendar(firstWeekday: 2))
        #expect(all.first?.items.count == 5 && all.map(\.items.count).reduce(0, +) == items.count)
        #expect(gallerySections([Item](), created: \.created, edited: \.edited, now: now).isEmpty)
    }    /// The library caps Recently edited at one row of tiles: what doesn't fit goes back to its date, shown once.
    @Test func recentlyEditedCappedToARowShowsEachRecordingOnce() {
        let row = names(2, recent: 1)
        #expect(row["Recently edited"] == ["edited a"] && row["Older"] == ["sunday", "last month", "edited b"])
        #expect(row.values.flatMap(\.self).sorted() == items.map(\.name).sorted())
    }
}

@Suite struct ShortcutCapture {
    func press(_ code: Int, _ chars: String, cmd: Bool = false, ctrl: Bool = false, opt: Bool = false, shift: Bool = false) -> ShortcutPress? {
        shortcutPress(t: 1, keyCode: code, characters: chars, command: cmd, control: ctrl, option: opt, shift: shift)
    }
    @Test func keepsShortcutsAndNeverPlainTyping() {
        #expect(press(0, "a") == nil && press(0, "a", shift: true) == nil && press(49, " ") == nil && press(51, "") == nil)
        #expect(press(21, "4", cmd: true, shift: true)?.caps == ["⇧", "⌘", "4"])
        #expect(press(51, "", opt: true)?.caps == ["⌥", "⌫"])
        #expect(press(8, "c", cmd: true, ctrl: true)?.caps == ["⌃", "⌘", "C"])
        #expect(press(53, "\u{1b}")?.caps == ["esc"])                          // Esc on its own counts
    }
    @Test func showsForAMomentWithShortFades() {
        let keys = [ShortcutPress(t: 1, modifiers: ["⌘"], key: "S"), ShortcutPress(t: 5, modifiers: ["⌘"], key: "Z"), ShortcutPress(t: 5.5, modifiers: ["⌘"], key: "C")]
        #expect(keystrokeAt(keys, 0.9) == nil)
        #expect(abs(keystrokeAt(keys, 1.075)!.alpha - 0.5) < 1e-9)              // fading in
        #expect(keystrokeAt(keys, 1.6)!.alpha == 1 && keystrokeAt(keys, 2.3) == nil)
        #expect(keystrokeAt(keys, 5.45)!.press.key == "Z" && keystrokeAt(keys, 5.45)!.alpha == 1) // cut short by ⌘C, no fade out
        #expect(keystrokeAt(keys, 5.7)!.press.key == "C")
    }
}

@Suite struct Countdown {
    @Test func countsDownThenStarts() async {
        var shown: [Int] = [], waits = 0
        #expect(await countdown(3, tick: { shown.append($0) }, sleep: { waits += 1 }))
        #expect(shown == [3, 2, 1] && waits == 3) // the start is deferred by one second per number
        #expect(await countdown(0, tick: { _ in Issue.record("no countdown when off") }, sleep: {}))
    }
    @Test func cancellingStopsBeforeTheStart() async {
        var shown: [Int] = []
        #expect(await !countdown(5, tick: { shown.append($0) }, sleep: { if shown.count == 2 { throw CancellationError() } }))
        #expect(shown == [5, 4])
        let run = Task { await countdown(3, tick: { _ in }) }
        run.cancel()
        #expect(await !run.value)
    }
}

@Suite struct MicMeterLevel {
    @Test func mapsDecibelsToAFill() {
        #expect(meterLevel(dB: -160) == 0) // silence, or no microphone
        #expect(meterLevel(dB: -50) == 0)
        #expect(meterLevel(dB: -25) == 0.5)
        #expect(meterLevel(dB: 0) == 1)
        #expect(meterLevel(dB: 6) == 1)
    }

    @Test func risesAtOnceAndFallsSlowly() {
        #expect(smoothedLevel(shown: 0.2, heard: 0.9) == 0.9) // a loud sound shows straight away
        #expect(abs(smoothedLevel(shown: 0.8, heard: 0) - 0.6) < 1e-9) // then falls a quarter of the way per tick
        var shown = 1.0
        for _ in 0..<20 { shown = smoothedLevel(shown: shown, heard: 0) }
        #expect(shown < 0.01) // and settles within two seconds of silence
    }
}

@Suite struct Pauses {
    // 20 s at 0.1 s windows: silence to 2 s, speech 2–5 s, a 4 s pause, speech 9–10 s, a 0.8 s breath, speech 10.8–14 s,
    // then silence to the end.
    let voice: [ClosedRange<Double>] = {
        let levels = (0..<200).map { i -> Double in
            let t = Double(i) / 10
            return (2..<5).contains(t) || (9..<10).contains(t) || (10.8..<14).contains(t) ? 0.1 : 0
        }
        return voiceRanges(levels: levels, window: 0.1)
    }()

    @Test func findsPausesLongerThanTheMinimumWithPadding() {
        let p = longPauses(voice: voice, in: [Trim(start: 0, end: 20)], PauseOptions(minimum: 1.5, padding: 0.25))
        #expect(p.count == 3) // the breath is kept
        #expect(abs(p[0].start - 0) < 1e-6 && abs(p[0].end - 1.75) < 1e-6)  // no padding at the edge
        #expect(abs(p[1].start - 5.25) < 1e-6 && abs(p[1].end - 8.75) < 1e-6)
        #expect(abs(p[2].start - 14.25) < 1e-6 && abs(p[2].end - 20) < 1e-6)
        #expect(longPauses(voice: voice, in: [Trim(start: 0, end: 20)], PauseOptions(minimum: 6.5)).isEmpty)
        #expect(longPauses(voice: [], in: [Trim(start: 0, end: 20)], PauseOptions()).isEmpty) // no speech, nothing to cut
    }

    @Test func cuttingKeepsTheSpeech() {
        var e = edits()
        e.removePauses(voice: voice, PauseOptions())
        let kept = e.keptSegments
        #expect(kept.count == 2)
        #expect(abs(kept[0].start - 1.75) < 1e-6 && abs(kept[0].end - 5.25) < 1e-6)
        #expect(abs(kept[1].start - 8.75) < 1e-6 && abs(kept[1].end - 14.25) < 1e-6)
        #expect(abs(outputDuration(e.timeMap) - 9) < 1e-6)
        // Running it again finds nothing new.
        #expect(e.pauses(voice: voice, PauseOptions()).isEmpty)
    }

    @Test func speedingUpLeavesOtherSpeedRegionsAlone() {
        var e = edits { $0.allSpeeds = [SpeedRegion(start: 6, end: 7, speed: 2)] }
        let o = PauseOptions(speedUp: true)
        e.removePauses(voice: voice, o)
        let r = e.allSpeeds.map { [$0.start, $0.end, $0.speed] }
        #expect(r == [[0, 1.75, 4], [5.25, 6, 4], [6, 7, 2], [7, 8.75, 4], [14.25, 20, 4]])
        // Split at every speed change: 0 | 1.75 | 5.25 | 6 | 7 | 8.75 | 14.25 | 20.
        #expect(e.keptSegments.map(\.start) == [0, 1.75, 5.25, 6, 7, 8.75, 14.25])
        #expect(e.pauses(voice: voice, o).isEmpty) // already sped up
        // 9 s at 1×, 1 s at 2×, and 10 s at 4×.
        #expect(abs(outputDuration(e.timeMap) - (9 + 0.5 + 10.0 / 4)) < 1e-6)
    }
}

@Suite struct TimelineLayout {
    // 0–20 s, trimmed to 2–18, with 6–8 cut and 10–14 at 4×: the timeline shows only what plays.
    let e = edits {
        $0.keptSegments = [Trim(start: 2, end: 6), Trim(start: 8, end: 18)]
        $0.allSpeeds = [SpeedRegion(start: 10, end: 14, speed: 4)]
    }

    @Test func cutsAndTrimTakeNoRoomAndSpeedsTakeTheirPlayedLength() {
        let m = e.timeMap
        #expect(abs(outputDuration(m) - (4 + 2 + 1 + 4)) < 1e-9) // 2–6, 8–10, 10–14 at 4×, 14–18
        #expect(sourceToOutput(m, 1) == 0)                       // before the trim: at the start
        #expect(abs(sourceToOutput(m, 6) - 4) < 1e-9)
        #expect(abs(sourceToOutput(m, 7) - 4) < 1e-9)            // inside the cut: where the video carries on
        #expect(abs(sourceToOutput(m, 12) - 6.5) < 1e-9)
        #expect(abs(sourceToOutput(m, 19) - 11) < 1e-9)          // after the trim: at the end
        #expect(abs(outputToSource(m, 4.5) - 8.5) < 1e-9)
        #expect(abs(outputToSource(m, 6.5) - 12) < 1e-9)
    }
}

@Suite struct ClipSpeed {
    @Test func settingAPiecesSpeedSplitsTheClipAndReplacesOnlyThatPiece() {
        var e = edits { $0.split(at: 5); $0.split(at: 10) } // 0–5, 5–10, 10–20
        e.setSpeed(4, from: 5, to: 10)
        #expect(e.allSpeeds.map { [$0.start, $0.end, $0.speed] } == [[5, 10, 4]])
        #expect(e.speed(ofSegment: 1) == 4 && e.speed(ofSegment: 0) == 1)
        #expect(abs(outputDuration(e.timeMap) - 16.25) < 1e-9)
        e.setSpeed(2, from: 5, to: 10)  // changed, not stacked
        #expect(e.allSpeeds.map(\.speed) == [2])
        e.setSpeed(1, from: 5, to: 10)  // back to normal: no region left
        #expect(e.allSpeeds.isEmpty && e.keptSegments.count == 3)
        // A range inside a piece splits it there.
        e.setSpeed(8, from: 12, to: 16)
        #expect(e.keptSegments.map(\.start) == [0, 5, 10, 12, 16])
        #expect(e.speed(ofSegment: 3) == 8)
    }

    @Test func oldSpeedRegionsAreSplitWhereTheSpeedChanges() {
        var e = edits { $0.allSpeeds = [SpeedRegion(start: 3, end: 7, speed: 2)] }
        e.splitAtSpeedChanges()
        #expect(e.keptSegments.map(\.start) == [0, 3, 7])
        #expect(e.speed(ofSegment: 1) == 2 && e.speed(ofSegment: 2) == 1)
        #expect(abs(outputDuration(e.timeMap) - 18) < 1e-9) // unchanged by the split
    }
}

@Suite struct Chapters {
    @Test func closeFlagsSitSideBySideInsteadOfHidingEachOther() {
        // "A" at 3.0 s and "Members & roles" at 3.4 s, a few points apart: the second moves just clear of the first.
        let flags = flagLayout([10, 300, 304, 306, 600], width: 640, icon: 18)
        #expect(flags.map(\.x) == [10, 300, 318, 336, 600])
        #expect(flags.map(\.room) == [290, 18, 18, 264, 40])
        #expect(flagLayout([], width: 640, icon: 18).isEmpty)
    }

    // 0–20 s, 4–6 cut, 10–14 at 2×. Markers at 1 s, 5 s (in the cut), 8 s and 12 s.
    let e = edits {
        $0.keptSegments = [Trim(start: 0, end: 4), Trim(start: 6, end: 20)]
        $0.allSpeeds = [SpeedRegion(start: 10, end: 14, speed: 2)]
        $0.allMarkers = [Marker(t: 12, name: "Wrap-up"), Marker(t: 1, name: "Setup"), Marker(t: 5, name: "Cut away"), Marker(t: 8, name: " Demo ")]
    }

    @Test func followCutsAndSpeedsAndStartAtZero() {
        let c = e.chapters(title: "My video")
        // Output: 0–4, 6–10 → 4–8, 10–14 at 2× → 8–10, 14–20 → 10–16. The first marker is past 0:00, so the opening
        // gets the title.
        #expect(c.map(\.name) == ["My video", "Setup", "Demo", "Wrap-up"])
        #expect(c.map(\.start) == [0, 1, 6, 9])
        #expect(c.map(\.end) == [1, 6, 9, 16])
    }

    @Test func aMarkerAtTheStartIsTheFirstChapter() {
        var e = edits()
        e.allMarkers = [Marker(t: 0.3, name: "Intro"), Marker(t: 10, name: "Main")]
        #expect(e.chapters(title: "x").map { [$0.start, $0.end] } == [[0, 10], [10, 20]])
        #expect(e.chapters(title: "x").first?.name == "Intro")
        #expect(edits().chapters(title: "x").isEmpty) // no markers, no chapters
    }

    @Test func movingAMarkerKeepsItInTheTrimAndInOrder() {
        var e = e
        #expect(e.moveMarker(0, to: 13.004) == 3) // Setup, from 1 s to past Wrap-up at 12 s
        #expect(e.allMarkers.map(\.name) == ["Cut away", " Demo ", "Wrap-up", "Setup"])
        #expect(e.allMarkers[3].t == 13)
        #expect(e.moveMarker(3, to: -5) == 0 && e.allMarkers[0].t == e.trim.start)
        #expect(e.moveMarker(9, to: 1) == nil)
    }

    @Test func summaryListsThemTheWayYouTubeReadsThem() {
        let md = summaryMarkdown(title: "My video", createdAt: Date(), edits: e, video: "v.mp4", poster: "p.jpg", transcript: "")
        #expect(md.contains("## Chapters\n\n0:00 My video\n0:01 Setup\n0:06 Demo\n0:09 Wrap-up\n"))
        #expect(md.contains("![Poster](p.jpg)"))
        #expect(!summaryMarkdown(title: "My video", createdAt: Date(), edits: e, video: "v.mp4", poster: nil, transcript: "").contains("Poster"))
        #expect(chapterTime(3725) == "1:02:05" && chapterTime(65) == "1:05")
        var bad = e
        bad.allMarkers[0].name = "  "
        #expect(validateEdits(bad, duration: 20).contains("Chapter 1: its name must be 1–80 characters."))
    }
}

@Suite struct CaptionLines {
    func words(_ list: [(String, Double, Double)]) -> [CaptionWord] { list.map { CaptionWord($0.0, start: $0.1, end: $0.2) } }

    @Test func breaksAtSentencesPausesAndLength() {
        let w = words([
            ("Hello", 0.0, 0.4), ("there.", 0.5, 0.9),                 // a sentence ends
            ("This", 1.0, 1.2), ("is", 1.3, 1.4), ("a", 1.5, 1.6), ("demo", 1.7, 2.0),
            ("after", 3.5, 3.8), ("a", 3.9, 4.0), ("pause", 4.1, 4.5),  // 1.5 s gap
        ])
        let lines = captionLines(w)
        #expect(lines.map(\.text) == ["Hello there.", "This is a demo", "after a pause"])
        #expect(lines[0].start == 0 && lines[0].end == 1.0)            // held until the next line, which is close
        #expect(lines[1].end == 2.0)                                     // not held across the pause
        let short = captionLines(words([("Hi.", 0, 0.3)]))
        #expect(short[0].end == 1.0)                                     // a quick line still shows for a second
    }

    @Test func keepsLinesShortEnoughToRead() {
        let w = (0..<20).map { CaptionWord("word\($0)", start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25) }
        let lines = captionLines(w)
        #expect(lines.allSatisfy { $0.text.count <= Captions.maxChars })
        #expect(lines.flatMap { $0.text.split(separator: " ") }.count == 20) // no word lost
    }

    @Test func splitsAndMovesWithinNeighbours() {
        var c = Captions(lines: [CaptionLine("one two three four", start: 1, end: 3), CaptionLine("next", start: 4, end: 5)])
        let split = c.split(0, at: 2)
        #expect(split)
        #expect(c.lines.map(\.text) == ["one two", "three four", "next"])
        #expect(c.lines[0].end == 2 && c.lines[1].start == 2)
        let oneWord = c.split(2, at: 4.5)
        #expect(!oneWord)
        c.move(1, to: 3.5)            // would run into "next"
        #expect(c.lines[1].start == 3 && c.lines[1].end == 4)
        c.move(1, to: 0)              // would run into "one two"
        #expect(c.lines[1].start == 2)
        #expect(c.line(at: 4.2)?.text == "next")
        #expect(c.line(at: 3.5) == nil)
    }

    @Test func trimsWithinNeighbours() {
        var c = Captions(lines: [CaptionLine("one", start: 1, end: 2), CaptionLine("two", start: 3, end: 4), CaptionLine("three", start: 5, end: 6)])
        c.trim(1, start: true, to: 1.5)    // stops at "one"'s end
        c.trim(1, start: false, to: 5.5)   // stops at "three"'s start
        #expect(c.lines[1].start == 2 && c.lines[1].end == 5)
        c.trim(1, start: true, to: 4.95)   // stays at least 0.2 s long
        #expect(c.lines[1].start == 4.8)
        c.trim(0, start: true, to: -1)
        #expect(c.lines[0].start == 0)
    }

    @Test func subtitlesFollowCutsAndSpeed() {
        // Trim 0–10 s, 2–4 s cut, 6–10 s at 2×: output time is t for t<2, t−2 for 4–6, 4 + (t−6)/2 after.
        var e = Edits(trim: Trim(start: 0, end: 10))
        e.split(at: 2); e.split(at: 4); e.removeSegment(1)
        e.setSpeed(2, from: 6, to: 10)
        let lines = [CaptionLine("first", start: 0.5, end: 1.5), CaptionLine("gone", start: 2.5, end: 3.5),
                     CaptionLine("fast", start: 7, end: 9)]
        #expect(srt(lines, e.timeMap) == """
        1
        00:00:00,500 --> 00:00:01,500
        first

        2
        00:00:04,500 --> 00:00:05,500
        fast

        """)
    }
}

@Suite struct Updates {
    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, dmg: Bool = true) -> Release {
        let v = AppVersion(tag).map { "\($0)" } ?? tag
        let asset = Release.Asset(name: "RecordStudio-\(v).dmg", url: URL(string: "https://github.com/kasapovicc/RecordStudio/releases/download/\(tag)/RecordStudio-\(v).dmg")!, size: 1)
        return Release(tag: tag, draft: draft, prerelease: prerelease, assets: dmg ? [asset] : [])
    }

    @Test(arguments: [
        ("1.0.0-beta.1", "1.0.0"), ("1.0.0-alpha", "1.0.0-beta"), ("1.0.0-beta.2", "1.0.0-beta.10"), ("1.0.0-beta", "1.0.0-beta.1"),
        ("1.0.0-1", "1.0.0-beta"), ("0.9.9", "1.0.0-beta.1"), ("1.2.0", "1.10.0"), ("v1.0.0", "1.0.1"),
    ])
    func ordersVersions(_ older: String, _ newer: String) throws {
        let a = try #require(AppVersion(older)), b = try #require(AppVersion(newer))
        #expect(a < b)
        #expect(!(b < a))
    }

    @Test func parsesTagsAndRejectsJunk() {
        #expect(AppVersion("v1.2") == AppVersion("1.2.0"))
        #expect(AppVersion("1.0.0-beta.1+build.7") == AppVersion("1.0.0-beta.1"))
        #expect(AppVersion("v1.0.0-beta.1")?.description == "1.0.0-beta.1")
        #expect(AppVersion("1.0.0-beta.1")?.isBeta == true && AppVersion("1.0.0")?.isBeta == false)
        for junk in ["", "v", "1..0", "1.0.0.0", "1.0.0-", "1.0.0-beta..1", "one.two", "-1.0.0", "+1.0"] {
            #expect(AppVersion(junk) == nil, "\(junk)")
        }
    }

    @Test func offersBetasOnlyWhenOptedIn() throws {
        let current = try #require(AppVersion("1.0.0"))
        // A label makes a release a beta even when GitHub's pre-release tick is off, as on v1.0.0-beta.1.
        let releases = [release("v1.1.0-beta.1"), release("v1.0.1"), release("v1.2.0", prerelease: true), release("v0.9.0")]
        #expect(availableUpdate(releases, current: current, includeBetas: false)?.tag == "v1.0.1")
        #expect(availableUpdate(releases, current: current, includeBetas: true)?.tag == "v1.2.0")
        #expect(availableUpdate([release("v1.1.0-beta.1")], current: current, includeBetas: false) == nil)
    }

    @Test func offersNothingOlderUnpublishedOrUninstallable() throws {
        let current = try #require(AppVersion("1.0.0"))
        #expect(availableUpdate([release("v1.0.0"), release("v0.3.0-beta.1")], current: current, includeBetas: true) == nil)
        #expect(availableUpdate([release("v2.0.0", draft: true)], current: current, includeBetas: true) == nil)
        #expect(availableUpdate([release("v2.0.0", dmg: false), release("v1.5.0")], current: current, includeBetas: false)?.tag == "v1.5.0")
        #expect(availableUpdate([release("latest")], current: current, includeBetas: true) == nil)
        // A beta build is offered the full release it led up to.
        let beta = try #require(AppVersion("1.0.0-beta.1"))
        #expect(availableUpdate([release("v1.0.0")], current: beta, includeBetas: false)?.tag == "v1.0.0")
    }

    @Test func picksTheDiskImageForTheVersion() throws {
        let base = "https://github.com/kasapovicc/RecordStudio/releases/download/v1.1.0/"
        func asset(_ name: String, at prefix: String? = nil) -> Release.Asset { Release.Asset(name: name, url: URL(string: (prefix ?? base) + name)!, size: 1) }
        var r = Release(tag: "v1.1.0", assets: [asset("notes.txt"), asset("RecordStudio-1.0.0.dmg"), asset("RecordStudio-1.1.0.dmg")])
        #expect(r.installer?.name == "RecordStudio-1.1.0.dmg")
        r.assets = [asset("notes.txt"), asset("RecordStudio-universal.dmg")]
        #expect(r.installer?.name == "RecordStudio-universal.dmg")
        r.assets = [asset("RecordStudio-a.dmg"), asset("RecordStudio-b.dmg")]
        #expect(r.installer == nil)   // ambiguous
        r.assets = [asset("RecordStudio-1.1.0.dmg", at: "http://github.com/x/"), asset("RecordStudio-1.1.0.dmg", at: "https://example.com/x/")]
        #expect(r.installer == nil)   // only https from github.com
    }

    @Test func readsTheReleasesAPI() throws {
        let json = """
        [{"tag_name": "v1.0.0-beta.1", "name": "RecordStudio 1.0.0 beta 1", "body": "## New\\n- Captions", "draft": false, "prerelease": false,
          "html_url": "https://github.com/kasapovicc/RecordStudio/releases/tag/v1.0.0-beta.1", "id": 1,
          "assets": [{"name": "RecordStudio-1.0.0-beta.1.dmg", "size": 12345, "content_type": "application/x-apple-diskimage",
                      "browser_download_url": "https://github.com/kasapovicc/RecordStudio/releases/download/v1.0.0-beta.1/RecordStudio-1.0.0-beta.1.dmg",
                      "digest": "sha256:94F5382D9E73A109017DA1A6720C3B96522B7B6DE04B6CB1BA0E199B5553E640"}]}]
        """
        let r = try #require(try JSONDecoder().decode([Release].self, from: Data(json.utf8)).first)
        #expect(r.isBeta && r.version == AppVersion("1.0.0-beta.1"))
        #expect(r.notes == "## New\n- Captions")
        let dmg = try #require(r.installer)
        #expect(dmg.size == 12345)
        #expect(dmg.sha256 == "94f5382d9e73a109017da1a6720c3b96522b7b6de04b6cb1ba0e199b5553e640")
        #expect(Release.Asset(name: "x", url: dmg.url, size: 1, digest: "md5:abc").sha256 == nil)
        #expect(Release.Asset(name: "x", url: dmg.url, size: 1, digest: "sha256:abc").sha256 == nil)
    }

    @Test func onlyTestBuildsMentionTheUpdateToken() {
        let publicBuild = noReleasesMessage(repository: "kasapovicc/RecordStudio", signedIn: false)
        #expect(publicBuild == "GitHub has no releases for kasapovicc/RecordStudio that this copy can see.")
        #expect(!publicBuild.contains("token") && !publicBuild.contains("private"))
        #expect(noReleasesMessage(repository: "kasapovicc/RecordStudio", signedIn: true).contains("update token"))
    }

    @Test func signsInOnlyWithAToken() throws {
        let anonymous = releasesRequest(repository: "kasapovicc/RecordStudio", token: nil)
        #expect(anonymous.url?.absoluteString == "https://api.github.com/repos/kasapovicc/RecordStudio/releases?per_page=30")
        #expect(anonymous.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(releasesRequest(repository: "kasapovicc/RecordStudio", token: "abc").value(forHTTPHeaderField: "Authorization") == "Bearer abc")

        let browser = try #require(URL(string: "https://github.com/kasapovicc/RecordStudio/releases/download/v1.1.0/RecordStudio-1.1.0.dmg"))
        let api = try #require(URL(string: "https://api.github.com/repos/kasapovicc/RecordStudio/releases/assets/42"))
        let asset = Release.Asset(name: "RecordStudio-1.1.0.dmg", url: browser, api: api, size: 1)
        let signed = asset.downloadRequest(token: "abc")
        #expect(signed.url == api)
        #expect(signed.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
        #expect(signed.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        let plain = asset.downloadRequest(token: nil)
        #expect(plain.url == browser && plain.value(forHTTPHeaderField: "Authorization") == nil)
        // An API link anywhere but api.github.com never gets the token.
        let elsewhere = Release.Asset(name: asset.name, url: browser, api: URL(string: "https://example.com/assets/42"), size: 1)
        #expect(elsewhere.downloadRequest(token: "abc").url == browser)
        #expect(elsewhere.downloadRequest(token: "abc").value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func keepsTheTokenOffRedirectsToOtherHosts() throws {
        let api = try #require(URL(string: "https://api.github.com/repos/x/y/releases/assets/42"))
        var next = URLRequest(url: try #require(URL(string: "https://release-assets.githubusercontent.com/file?sig=1")))
        next.setValue("Bearer abc", forHTTPHeaderField: "Authorization")
        next.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let stripped = redirect(next, from: api)
        #expect(stripped.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(stripped.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
        next.url = URL(string: "https://api.github.com/repos/x/y/releases/assets/43")
        #expect(redirect(next, from: api).value(forHTTPHeaderField: "Authorization") == "Bearer abc")
    }

    @Test func readsTheAPIDownloadLink() throws {
        let json = """
        {"name": "RecordStudio-1.1.0.dmg", "size": 1, "url": "https://api.github.com/repos/x/y/releases/assets/42",
         "browser_download_url": "https://github.com/x/y/releases/download/v1.1.0/RecordStudio-1.1.0.dmg"}
        """
        let asset = try JSONDecoder().decode(Release.Asset.self, from: Data(json.utf8))
        #expect(asset.api?.absoluteString == "https://api.github.com/repos/x/y/releases/assets/42")
        #expect(asset.url.host() == "github.com")
    }

    @Test func checksAtMostDailyAndNeverWhenOptedOut() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(isUpdateCheckDue(automatic: true, lastCheck: nil, now: now))
        #expect(!isUpdateCheckDue(automatic: true, lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(isUpdateCheckDue(automatic: true, lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(isUpdateCheckDue(automatic: true, lastCheck: now.addingTimeInterval(3600), now: now))   // clock moved back
        #expect(!isUpdateCheckDue(automatic: false, lastCheck: nil, now: now))
        #expect(!isUpdateCheckDue(automatic: false, lastCheck: now.addingTimeInterval(-30 * 24 * 3600), now: now))
    }
}

// Short signals, one test at a time: noise reduction is slow in a debug build, and longer runs of it alongside the
// other suites stalled the whole test run. The time limit turns any stall into a named failure.
@Suite(.serialized, .timeLimit(.minutes(1))) struct MicrophoneCleanup {
    static let rate = 48_000.0

    /// Repeatable white noise between -amplitude and amplitude.
    static func noise(_ count: Int, amplitude: Float, seed: UInt64 = 42) -> [Float] {
        var s = seed
        return (0..<count).map { _ in
            s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(Double(s >> 11) / Double(1 << 53)) * 2 - 1) * amplitude
        }
    }
    static func sine(seconds: Double, hz: Double, amplitude: Double, on: (Double) -> Bool = { _ in true }) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            return on(t) ? Float(amplitude * sin(2 * .pi * hz * t)) : 0
        }
    }
    static func rms(_ x: [Float], from a: Double, to b: Double) -> Double {
        let part = x[Int(a * rate)..<Int(b * rate)]
        return (part.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(part.count)).squareRoot()
    }
    static func db(_ after: Double, _ before: Double) -> Double { 20 * log10(after / before) }

    @Test func measuresLoudnessTheBS1770Way() throws {
        // A full-scale 1 kHz sine in one channel is -3.01 LUFS; half as loud is 6 dB less, and twice over (a mono
        // microphone spread to both sides, as the export plays it) 3 dB more.
        let full = Self.sine(seconds: 1, hz: 1000, amplitude: 1), half = Self.sine(seconds: 1, hz: 1000, amplitude: 0.5)
        #expect(abs(try #require(integratedLoudness([full], rate: Self.rate)) + 3.01) < 0.1)
        #expect(abs(try #require(integratedLoudness([half], rate: Self.rate)) + 9.03) < 0.1)
        #expect(abs(try #require(integratedLoudness([half], rate: Self.rate, playedAs: 2)) + 6.02) < 0.1)
        #expect(abs(try #require(integratedLoudness([half, half], rate: Self.rate)) + 6.02) < 0.1)
        #expect(integratedLoudness([[Float](repeating: 0, count: 48_000)], rate: Self.rate) == nil)
        #expect(integratedLoudness([Array(full.prefix(9_600))], rate: Self.rate) == nil) // shorter than one 400 ms block
    }

    @Test func turnsTheNoiseDownBetweenWordsAndKeepsTheVoice() {
        // A 440 Hz "voice" from 0.3 to 0.7 s over steady hiss.
        let voice = Self.sine(seconds: 1, hz: 440, amplitude: 0.3) { $0 >= 0.3 && $0 < 0.7 }
        let hiss = Self.noise(voice.count, amplitude: 0.05)
        let x = zip(voice, hiss).map { $0 + $1 }
        for (strength, minimum) in [(MicCleanup.Noise.light, 6.0), (.strong, 15.0)] {
            let y = reduceNoise(x, strength)
            #expect(y.count == x.count)
            #expect(Self.db(Self.rms(y, from: 0.02, to: 0.25), Self.rms(x, from: 0.02, to: 0.25)) < -minimum, "\(strength)")
            #expect(Self.db(Self.rms(y, from: 0.75, to: 0.98), Self.rms(x, from: 0.75, to: 0.98)) < -minimum, "\(strength)")
            #expect(abs(Self.db(Self.rms(y, from: 0.4, to: 0.6), Self.rms(x, from: 0.4, to: 0.6))) < 2, "\(strength)")
        }
        #expect(reduceNoise(x, .off) == x)
        let silence = [Float](repeating: 0, count: 48_000)
        #expect(reduceNoise(silence, .strong) == silence)
    }

    @Test func raisesAQuietRecordingToTheTargetWithoutClipping() throws {
        // Speech-like bursts, a quarter second on and off, at about -37 LUFS, plus one loud click in a pause. The
        // limiter's recovery from the click takes a little off, hence the wider tolerance.
        var quiet = Self.sine(seconds: 1, hz: 300, amplitude: 0.02) { Int($0 * 4) % 2 == 0 }
        quiet[14_400] = 0.5
        var channels = [quiet]
        let gain = normalizeLoudness(&channels, rate: Self.rate, playedAs: 2)
        #expect(gain > 15 && gain <= MicCleanup.maxGain)
        #expect(abs(try #require(integratedLoudness(channels, rate: Self.rate, playedAs: 2)) - MicCleanup.target) < 1)
        #expect(channels[0].allSatisfy { abs($0) <= MicCleanup.ceiling + 1e-6 })

        // A loud one comes down, and silence is left alone.
        var loud = [Self.sine(seconds: 1, hz: 1000, amplitude: 0.8)]
        normalizeLoudness(&loud, rate: Self.rate)
        #expect(abs(try #require(integratedLoudness(loud, rate: Self.rate)) - MicCleanup.target) < 0.5)
        var silent = [[Float](repeating: 0, count: 48_000)]
        let none = normalizeLoudness(&silent, rate: Self.rate)
        #expect(none == 0)
    }

    @Test func cleansAMonoMicrophoneSpreadToBothSidesOnce() throws {
        let one = zip(Self.sine(seconds: 1, hz: 440, amplitude: 0.05) { $0 >= 0.4 }, Self.noise(48_000, amplitude: 0.01)).map { $0 + $1 }
        let out = cleanMicrophone([one, one], rate: Self.rate, MicCleanup(noise: .light, normalize: true))
        #expect(out.count == 2 && out[0] == out[1])
        #expect(abs(try #require(integratedLoudness(out, rate: Self.rate)) - MicCleanup.target) < 0.5)
        #expect(cleanMicrophone([one, one], rate: Self.rate, MicCleanup()) == [one, one])
    }

    @Test func fftRoundTripsAndFindsATone() {
        let fft = FFT(64)
        var re = (0..<64).map { sin(2 * .pi * 4 * Double($0) / 64) }, im = [Double](repeating: 0, count: 64)
        let original = re
        fft.transform(&re, &im, inverse: false)
        let peak = (0..<32).max { hypot(re[$0], im[$0]) < hypot(re[$1], im[$1]) }
        #expect(peak == 4)
        fft.transform(&re, &im, inverse: true)
        #expect(zip(re, original).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(im.allSatisfy { abs($0) < 1e-9 })
    }

    @Test func isStoredOnlyWhenOn() throws {
        let old = try JSONDecoder().decode(Edits.self, from: JSONEncoder().encode(Edits(trim: Trim(start: 0, end: 5))))
        #expect(old.micCleanup == nil)
        #expect(!MicCleanup().isOn && MicCleanup(noise: .light).isOn && MicCleanup(normalize: true).isOn)
        var e = Edits(trim: Trim(start: 0, end: 5))
        e.micCleanup = MicCleanup(noise: .strong, normalize: true)
        #expect(try JSONDecoder().decode(Edits.self, from: JSONEncoder().encode(e)).micCleanup == e.micCleanup)
    }
}

@Suite(.timeLimit(.minutes(1))) struct PausingARecording {
    @Test func mapsRecordingTimeAroundAPause() {
        var c = RecordingClock()
        #expect(c.time(at: 100) == nil && c.elapsed(at: 100) == 0)
        c.begin(at: 100)
        #expect(c.time(at: 102) == 2 && c.time(at: 99) == nil)
        c.pause(at: 103)
        // Nothing is recorded while paused, and the time shown stands still.
        #expect(c.isPaused && c.time(at: 104) == nil && c.elapsed(at: 104) == 3 && c.elapsed(at: 107) == 3)
        c.pause(at: 105) // already paused: ignored
        c.resume(at: 108)
        #expect(!c.isPaused && c.pauses.count == 1)
        // After the pause, time carries on from where it stopped; before it, nothing moved.
        #expect(c.time(at: 108) == 3 && c.time(at: 110) == 5 && c.time(at: 102) == 2 && c.pausedTime(before: 102) == 0)
        c.pause(at: 111)
        c.resume(at: 111.5)
        #expect(c.pausedTime(before: 112) == 5.5 && c.time(at: 112) == 6.5 && c.elapsed(at: 112) == 6.5)
        c.resume(at: 120) // not paused: ignored
        #expect(c.pauses.count == 2 && c.time(at: 120) == 14.5)
    }

    @Test func shiftsCursorAndShortcutTimesByThePausedTime() throws {
        var c = RecordingClock()
        c.begin(at: 50)
        c.pause(at: 53)
        c.resume(at: 58) // 5 seconds paused
        // The cursor is polled every half second of host time, as the tracker does; a shortcut is pressed at 59.
        let polled = stride(from: 50.0, through: 60.0, by: 0.5).compactMap { h in c.time(at: h).map { (h, $0) } }
        let kept = polled.map(\.1)
        #expect(kept == [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5])
        #expect(!polled.contains { $0.0 >= 53 && $0.0 < 58 }) // nothing from the pause
        let cursor = kept.map { CursorSample(t: $0, x: 0.5, y: 0.5, down: false) }
        #expect(zip(cursor, cursor.dropFirst()).allSatisfy { $1.t - $0.t == 0.5 }) // no jump where the pause was
        let t = try #require(c.time(at: 59))
        let press = try #require(shortcutPress(t: t, keyCode: 8, characters: "c", command: true, control: false, option: false, shift: false))
        #expect(press.t == 4)
        #expect(c.time(at: 55) == nil) // a shortcut pressed while paused isn't kept
    }
}

@Suite struct InsertedClips {
    func clip(_ length: Double, at: Double = 0) -> InsertedClip { InsertedClip(path: "/clip.mp4", name: "Clip", at: at, length: length, width: 1920, height: 1080) }

    @Test func mapsTimelineTimeToRecordingTimeAroundClips() {
        var e = edits()
        e.allClips = [clip(2, at: 5), clip(3, at: 10)] // recording 0–5, clip, recording 5–8, clip, recording 8–20
        #expect(e.recordingTime(4) == 4 && e.recordingTime(6) == nil && e.recordingTime(8) == 6 && e.recordingTime(12) == nil && e.recordingTime(13) == 8)
        #expect(e.timelineTime(4) == 4 && e.timelineTime(5) == 7 && e.timelineTime(8) == 13 && e.timelineTime(20) == 25)
        #expect(e.timelineDuration(20) == 25 && e.clipIndex(at: 11) == 1 && e.clipIndex(at: 9) == nil)
        let runs = e.recordingRuns(duration: 20)
        #expect(runs.map(\.start) == [0, 5, 8] && runs.map(\.end) == [5, 8, 20] && runs.map(\.shift) == [0, 2, 5])
        #expect(e.timelineRanges([3.0...6.0]) == [3.0...5.0, 7.0...8.0])
        // With no clips, timeline time is recording time.
        #expect(edits().timelineTime(7) == 7 && edits().recordingTime(7) == 7)
    }

    @Test func insertingMakesItLongerAndMovesWhatFollows() {
        var e = edits { e in
            e.zooms = [Zoom(start: 2, end: 3, scale: 2), Zoom(start: 7, end: 9, scale: 2), Zoom(start: 12, end: 14, scale: 2)]
            e.callouts = [Callout(text: "Hi", start: 11, end: 12, x: 0, y: 0)]
            e.allMarkers = [Marker(t: 15, name: "Later")]
            e.allSpeeds = [SpeedRegion(start: 16, end: 18, speed: 2)]
        }
        let before = outputDuration(e.timeMap)
        e.insertClip(clip(4), at: 8)
        #expect(e.allClips.first?.at == 8 && abs(outputDuration(e.timeMap) - (before + 4)) < 1e-9)
        // What was after 8 s is 4 s later; the zoom across it is split there, so the clip isn't zoomed.
        #expect(e.zooms.map(\.start) == [2, 7, 12, 16] && e.zooms.map(\.end) == [3, 8, 13, 18])
        #expect(e.callouts.first?.start == 15 && e.allMarkers.first?.t == 19 && e.allSpeeds.first?.start == 20)
        #expect(e.keptSegments.map(\.start) == [0, 8, 12] && e.keptSegments.map(\.end) == [8, 12, 24])
        // It plays whole at normal speed: output 8–12 s is the clip.
        #expect(e.clipIndex(at: outputToSource(e.timeMap, 10)) == 0)
        #expect(validateEdits(e, duration: 20).isEmpty)
        // Dropped inside a clip, the next goes before or after it, whichever is nearer.
        #expect(e.insertionPoint(near: 9) == 8 && e.insertionPoint(near: 11.5) == 12)
        // Near a split it snaps there; outside the trim it goes at the trim's ends.
        #expect(e.insertionPoint(near: 12.2, snap: 0.3) == 12 && e.insertionPoint(near: 30) == 24)
    }

    @Test func movesAClipWithWhatsOverItAndRemovesIt() {
        var e = edits()
        e.insertClip(clip(4), at: 5)
        e.zooms = [Zoom(start: 6, end: 7, scale: 2), Zoom(start: 12, end: 13, scale: 2)] // one over the clip, one after
        let length = outputDuration(e.timeMap)
        e.split(at: 15)
        e.moveClip(0, to: 15)
        // The clip now plays from recording time 10, and its zoom went with it; the other zoom moved back.
        #expect(e.allClips.first?.at == 11 && e.recordingTime(10.5) == 10.5 && e.recordingTime(11) == nil && e.timelineTime(11) == 15)
        #expect(Set(e.zooms.map(\.start)) == [8, 12] && abs(outputDuration(e.timeMap) - length) < 1e-9)
        // Onto itself it doesn't move.
        let moved = e
        e.moveClip(0, to: 13)
        #expect(e == moved)
        // Removing it takes its time out, and what was after it moves back.
        e.removeClip(0)
        #expect(e.allClips.isEmpty && abs(outputDuration(e.timeMap) - 20) < 1e-9 && e.zooms.map(\.start) == [8])
    }

    @Test func holdsTheCursorStillWhileAClipPlays() {
        var e = edits()
        e.insertClip(clip(3), at: 2)
        let moved = e.timelineCursor([CursorSample(t: 1, x: 0.1, y: 0.1, down: false), CursorSample(t: 3, x: 0.9, y: 0.9, down: false)])
        #expect(moved.map(\.t) == [1, 5, 6])
        #expect(cursorAt(moved, 4).x == 0.1) // still where it was during the clip
        #expect(e.timelineKeys([ShortcutPress(t: 2.5, modifiers: ["⌘"], key: "C")]).first?.t == 5.5)
    }

    @Test func keepsAClipsQuietOutOfPauses() {
        var e = edits()
        e.insertClip(clip(4), at: 10)
        // Speech up to 9 s and from 15 s on the timeline; the clip (10–14) has no microphone but isn't a pause.
        let found = e.pauses(voice: [0...9, 15...24], PauseOptions(minimum: 0.5, padding: 0.1, speedUp: false))
        #expect(!found.contains { $0.end > 10 && $0.start < 14 })
        #expect(found.contains { $0.start < 10 && $0.end > 9.5 } && found.contains { $0.start >= 14 && $0.end < 15 })
    }

    @Test func fitsAClipWithoutStretchingAndValidatesClips() throws {
        let f = clipFit(width: 1080, height: 1920, inside: 1600, 1000) // a phone video in a wide frame
        #expect(abs(f.height - 1000) < 1e-9 && abs(f.width - 562.5) < 1e-9 && abs(f.x - 518.75) < 1e-9 && abs(f.y) < 1e-9)
        var e = edits()
        e.allClips = [clip(2, at: 3), clip(2, at: 4)]
        #expect(validateEdits(e, duration: 20).contains { $0.contains("overlaps") })
        e.allClips = [clip(2, at: 3)]
        e.trim.end = 22
        #expect(validateEdits(e, duration: 20).isEmpty) // the trim reaches the end of the longer timeline
        #expect(try JSONDecoder().decode(Edits.self, from: JSONEncoder().encode(e)) == e)
    }
}

@Suite struct VideoOverlays {
    /// A 4 s video playing from timeline time 2, shown 3–5 (its first second trimmed off).
    func overlay() -> Annotation {
        var a = Annotation(kind: .video, start: 3, end: 5, x: 0.6, y: 0.6, w: 0.3, h: 0.3)
        a.video = OverlayVideo(path: "/overlay.mp4", name: "Shot", at: 2, length: 4, width: 1920, height: 1080)
        return a
    }

    @Test func splitsAndTrimsWithoutMovingWhatPlays() throws {
        var e = edits()
        e.allAnnotations = [overlay()]
        let didSplit = e.split(at: 4)
        #expect(didSplit)
        #expect(e.allAnnotations.map(\.start) == [3, 4] && e.allAnnotations.allSatisfy { $0.video?.at == 2 })
        #expect(e.videoOverlays.count == 1 && e.videoOverlays.first?.end == 5) // drawn as one, on one track
        e.allAnnotations[0].start = 2.5 // trimming the front shows more of the video, at the same time
        #expect(e.allAnnotations[0].video?.at == 2 && validateEdits(e, duration: 20).isEmpty)
        e.allAnnotations[0].start = 1.5
        #expect(validateEdits(e, duration: 20).contains { $0.contains("past the ends of its video") })
    }

    @Test func movesItsVideoWithIt() throws {
        var a = overlay()
        a.shift(by: 1.5)
        #expect(a.start == 4.5 && a.end == 6.5 && a.video?.at == 3.5)
        // Inserting a clip before it moves it later, video and all.
        var e = edits()
        e.allAnnotations = [overlay()]
        e.insertClip(InsertedClip(path: "/clip.mp4", name: "Clip", length: 2, width: 1920, height: 1080), at: 1)
        let moved = try #require(e.allAnnotations.first)
        #expect(moved.start == 5 && moved.end == 7 && moved.video?.at == 4)
        #expect(try JSONDecoder().decode(Edits.self, from: JSONEncoder().encode(e)) == e)
    }
}

@Suite struct TeleprompterPace {
    @Test(arguments: [(PrompterPace.slower, 110.0), (.standard, 140), (.faster, 170)])
    func scrollsAtItsPaceFromTheStartAndHoldsStillWhilePaused(pace: PrompterPace, wpm: Double) {
        var c = PrompterClock(pace: pace)
        #expect(c.position(at: 100) == 0)          // the countdown: not started yet
        c.start(at: 103)
        #expect(c.position(at: 103) == 0)
        #expect(abs(c.position(at: 163) - wpm) < 1e-9) // a minute in
        c.pauseForRecording(true, at: 163)
        #expect(abs(c.position(at: 200) - wpm) < 1e-9) // paused: still
        c.pauseForRecording(false, at: 200)
        #expect(abs(c.position(at: 230) - wpm * 1.5) < 1e-9)
    }

    @Test func holdsNudgesAndChangesPaceFromWhereItIs() {
        var c = PrompterClock(pace: .standard, length: 300)
        c.hold(true, at: 0)
        c.start(at: 0)
        #expect(!c.isRunning && c.position(at: 30) == 0) // held from the panel before it began
        c.hold(false, at: 30)
        #expect(abs(c.position(at: 60) - 70) < 1e-9)
        c.setPace(.faster, at: 60)
        #expect(abs(c.position(at: 90) - 155) < 1e-9)  // 70 + half a minute at 170
        c.nudge(by: -20, at: 90)
        #expect(abs(c.position(at: 90) - 135) < 1e-9)
        c.nudge(by: -500, at: 90)
        #expect(c.position(at: 90) == 0)
        #expect(c.position(at: 1000) == 300)            // stops at the end of the notes
        #expect(wordCount("  Hello there,\nworld!  ") == 3 && wordCount("## Intro\nHi") == 2 && prompterText("# Intro\nA # B") == "Intro\nA # B")
    }

    @Test func savedFrameStaysOnAConnectedScreen() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 875), external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let fallback = CGRect(x: 440, y: 653, width: 560, height: 210)
        // Partly above the top: moved down under the menu bar.
        #expect(prompterFrame(saved: CGRect(x: 400, y: 800, width: 560, height: 210), screens: [main], fallback: fallback) == CGRect(x: 400, y: 665, width: 560, height: 210))
        // Left on a display that's since been unplugged: back to the default spot.
        #expect(prompterFrame(saved: CGRect(x: 2000, y: 300, width: 560, height: 210), screens: [main], fallback: fallback) == fallback)
        #expect(prompterFrame(saved: nil, screens: [main], fallback: fallback) == fallback)
        // Straddling two screens: kept on the one it's mostly on; wider than the screen: shrunk to fit.
        #expect(prompterFrame(saved: CGRect(x: 1300, y: 100, width: 560, height: 210), screens: [main, external], fallback: fallback) == CGRect(x: 1440, y: 100, width: 560, height: 210))
        #expect(prompterFrame(saved: CGRect(x: -50, y: 0, width: 2000, height: 210), screens: [main], fallback: fallback) == CGRect(x: 0, y: 0, width: 1440, height: 210))
        #expect(prompterFrame(saved: CGRect(x: 200, y: 200, width: 560, height: 210), screens: [main], fallback: fallback) == CGRect(x: 200, y: 200, width: 560, height: 210))
    }

    @Test func releasedNearTheTopCentreSettlesThere() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 875), home = CGRect(x: 440, y: 653, width: 560, height: 210)
        #expect(prompterHome(size: home.size, screen: main) == home)
        #expect(prompterSnap(CGRect(x: 470, y: 630, width: 560, height: 210), screen: main) == home)
        #expect(prompterSnap(home, screen: main) == nil)                                            // already there
        #expect(prompterSnap(CGRect(x: 200, y: 640, width: 560, height: 210), screen: main) == nil) // left where it was put
    }
}

@Test func arrowKeysMoveThroughTheLibraryGridSectionBySection() {
    // Three columns: a section of 5 (rows 0 1 2 / 3 4), then one of 2 (5 6).
    let counts = [5, 2]
    #expect(gridMove(2, dx: 1, dy: 0, counts: counts, columns: 3) == 3)  // right wraps into the next row
    #expect(gridMove(6, dx: 1, dy: 0, counts: counts, columns: 3) == 6)  // stays at the end
    #expect(gridMove(0, dx: -1, dy: 0, counts: counts, columns: 3) == 0)
    #expect(gridMove(2, dx: 0, dy: 1, counts: counts, columns: 3) == 4)                            // shorter row below: its last tile
    #expect(gridMove(4, dx: 0, dy: 1, counts: counts, columns: 3) == 6)                            // into the next section, same column if it has one
    #expect(gridMove(5, dx: 0, dy: -1, counts: counts, columns: 3) == 3)
    #expect(gridMove(1, dx: 0, dy: -1, counts: counts, columns: 3) == 1) // top row stays
    #expect(gridMove(6, dx: 0, dy: 1, counts: counts, columns: 3) == 6)
}

@Test func readoutsWriteEachKindOfValueOneWay() {
    #expect(Readout.percent(0.06) == "6%")
    #expect(Readout.percent(1) == "100%")
    #expect(Readout.finePercent(0.008) == "0.8%")
    #expect(Readout.scale(1.8) == "1.8×")
    #expect(Readout.seconds(0.30000000000000004) == "0.3 s")
    #expect(Readout.seconds(0.25) == "0.25 s")
    #expect(Readout.seconds(2) == "2 s")
    #expect(Readout.degrees(-180) == "-180°")
    #expect(Readout.size(2880, 1800) == "2880×1800")
}

@Suite struct Pasting {
    @Test func startsAtThePlayheadAndFitsBeforeTheEnd() {
        #expect(pasteRange(length: 3, at: 2, duration: 10) == (2, 5))
        #expect(pasteRange(length: 3, at: 9, duration: 10) == (7, 10))
        #expect(pasteRange(length: 30, at: 4, duration: 10) == (0, 10))
    }
}

@Suite struct MenuShortcuts {
    @Test func defaultEditorShortcutsDontClashWithTheMenus() {
        for (action, s) in ShortcutMap.defaults.bindings { #expect(ShortcutMap.menuShortcuts[s] == nil, "\(action)") }
        #expect(ShortcutMap.menuShortcuts[Shortcut("cmd+3")!] != nil)
        #expect(ShortcutMap.menuShortcuts[Shortcut("opt+cmd+i")!] != nil)
    }

    @Test func keycapsAndGroupsForSettings() {
        #expect(Shortcut("ctrl+opt+cmd+space")!.caps == ["⌃", "⌥", "⌘", "Space"])
        #expect(Shortcut("i")!.caps == ["I"] && Shortcut("ctrl+opt+cmd+r")!.symbol == "⌃⌥⌘R")
        // Every global shortcut is listed as working from anywhere or while recording, never in the editor's groups.
        for a in ShortcutAction.allCases { #expect(a.isGlobal == [.anywhere, .recording].contains(a.group), "\(a)") }
    }
}

@Suite struct Permissions {
    @Test func onlyScreenRecordingIsRequired() {
        #expect(Permission.allCases.filter(\.isRequired) == [.screenRecording])
    }

    @Test func eachOpensItsOwnPrivacyPage() {
        let urls = Permission.allCases.map(\.settingsURL.absoluteString)
        #expect(Set(urls).count == urls.count)
        #expect(urls.allSatisfy { $0.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_") })
    }

    @Test func screenRecordingAndInputMonitoringWaitForARelaunch() {
        #expect(Permission.allCases.filter(\.appliesAfterRelaunch) == [.screenRecording, .inputMonitoring])
    }

    @Test func asksOnceThenPointsToSystemSettings() {
        #expect(PermissionState.notAsked.action == .ask)
        #expect(PermissionState.denied.action == .openSettings)
        #expect(PermissionState.allowed.action == nil)
    }
}

@Suite struct Snapping {
    @Test func snapsEdgesAndCentreToTheFrame() {
        // Centre 0.01 off the middle snaps to it; the left edge 0.005 from the frame's edge snaps there.
        let a = snapBox(x: 0.41, y: 0.005, w: 0.2, h: 0.1, within: (0.02, 0.02))
        #expect(abs(a.x - 0.4) < 1e-9 && a.guideX == 0.5)
        #expect(a.y == 0 && a.guideY == 0)
        // Right edge onto the frame's right edge.
        #expect(abs(snapBox(x: 0.79, y: 0.3, w: 0.2, h: 0.1, within: (0.02, 0.02)).x - 0.8) < 1e-9)
        // Too far from every line: left alone.
        let b = snapBox(x: 0.2, y: 0.3, w: 0.1, h: 0.1, within: (0.02, 0.02))
        #expect(b.x == 0.2 && b.y == 0.3 && b.guideX == nil && b.guideY == nil)
    }
}

@Suite struct CropShapes {
    let source = (w: 1920.0, h: 1080.0)

    @Test func freeDragIsTheBoxBetweenThePoints() {
        #expect(cropRect(from: Point(x: 0.75, y: 0.5), to: Point(x: 0.25, y: 1.3), aspect: nil, source: source) == NRect(x: 0.25, y: 0.5, w: 0.5, h: 0.5))
    }

    @Test func aspectDragKeepsItsShapeAndStaysInside() {
        // Square in pixels on a 16:9 frame: normalized height is 16/9 of the width.
        let r = cropRect(from: Point(x: 0.1, y: 0.1), to: Point(x: 0.4, y: 0.2), aspect: 1, source: source)
        #expect(abs(r.w * 1920 - r.h * 1080) < 1e-6 && abs(r.w - 0.3) < 1e-9)
        // Dragged past the bottom: shrinks to fit.
        let s = cropRect(from: Point(x: 0.1, y: 0.5), to: Point(x: 0.9, y: 0.9), aspect: 1, source: source)
        #expect(abs(s.y + s.h - 1) < 1e-9 && abs(s.w * 1920 - s.h * 1080) < 1e-6)
        // Up and to the left of the start.
        let u = cropRect(from: Point(x: 0.5, y: 0.5), to: Point(x: 0.3, y: 0.4), aspect: 16.0 / 9, source: source)
        #expect(abs(u.x + u.w - 0.5) < 1e-9 && abs(u.y + u.h - 0.5) < 1e-9 && abs(u.w - u.h) < 1e-9)
    }

    @Test func fittingIsTheLargestOfThatShapeInTheFrame() {
        let v = cropFitting(aspect: 9.0 / 16, around: .full, source: source)
        #expect(v.h == 1 && abs(v.w * 1920 / 1080 - 9.0 / 16) < 1e-9 && abs(v.x + v.w / 2 - 0.5) < 1e-9)
        // Centred on the crop's centre, pushed back inside the frame.
        let r = cropFitting(aspect: 1, around: NRect(x: 0.8, y: 0, w: 0.2, h: 1), source: source)
        #expect(abs(r.x + r.w - 1) < 1e-9)
    }
}

@Suite struct PillPlacement {
    let size = CGSize(width: 400, height: 60)
    let visible = CGRect(x: 0, y: 80, width: 1440, height: 790) // AppKit space: the Dock below, the menu bar above

    @Test func wholeDisplayGoesToTheBottomLeftCorner() {
        #expect(pillOrigin(size: size, visible: visible, avoid: nil) == CGPoint(x: 16, y: 96))
    }

    @Test func staysOutsideTheRecordedArea() {
        // Room underneath: centred under it.
        let small = CGRect(x: 400, y: 400, width: 600, height: 300)
        #expect(pillOrigin(size: size, visible: visible, avoid: small) == CGPoint(x: 500, y: 324))
        // No room underneath: above it.
        let low = CGRect(x: 400, y: 100, width: 600, height: 300)
        #expect(pillOrigin(size: size, visible: visible, avoid: low) == CGPoint(x: 500, y: 416))
        // Nearly the whole display, but not its left side: the corner clear of it.
        let wide = CGRect(x: 500, y: 90, width: 940, height: 770)
        let p = pillOrigin(size: size, visible: visible, avoid: wide)
        #expect(!CGRect(origin: p, size: size).intersects(wide))
        // Centred under a window near the edge, but kept on the display.
        let edge = CGRect(x: 1300, y: 500, width: 140, height: 200)
        #expect(pillOrigin(size: size, visible: visible, avoid: edge).x == CGFloat(1440 - 400 - 16))
    }
}

@Suite struct WindowSizes {
    @Test func presetsArePixelsSoRetinaHalvesThePoints() {
        let p1080 = SizePreset.all[1]
        #expect(p1080.size == "1920 × 1080")
        #expect(p1080.points(scale: 2) == CGSize(width: 960, height: 540))
    }

    @Test func centresOnTheDisplayOrSaysItDoesntFit() {
        let area = CGRect(x: 0, y: 25, width: 1512, height: 900) // a 14" MacBook's visible frame, in points
        #expect(SizePreset(1920, 1080, "").centred(in: area, scale: 2) == CGRect(x: 276, y: 205, width: 960, height: 540))
        #expect(SizePreset(1080, 1920, "").centred(in: area, scale: 2) == nil) // 960 points tall
        #expect(SizePreset(1080, 1920, "").centred(in: area, scale: 2.5) != nil)
    }

    @Test func remembersByKeyAndReadsUnknownSizesAsCustom() {
        #expect(SizePreset(key: SizePreset.all[4].key) == SizePreset.all[4])
        #expect(SizePreset(key: "1000x700") == SizePreset(1000, 700, "Custom"))
        #expect(SizePreset(key: "nonsense") == nil)
        #expect(SizePreset(key: "0x700") == nil)
    }

    @Test func saysWhenTheWindowWouldntTakeTheSize() {
        let p = SizePreset(1280, 720, "")
        #expect(resizeShortfall(app: "Safari", asked: p, got: (1281, 720)) == nil) // rounding
        #expect(resizeShortfall(app: "Safari", asked: p, got: (1280, 800)) == "Safari won't go smaller than 1280 × 800.")
        #expect(resizeShortfall(app: "Notes", asked: p, got: (1000, 720)) == "Notes won't go bigger than 1000 × 720.")
        #expect(resizeShortfall(app: "Notes", asked: p, got: (1000, 900)) == "Notes kept the window at 1000 × 900.")
    }
}

@Suite struct AreaSelectionGeometry {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r = CGRect(x: 100, y: 100, width: 400, height: 200)
    let corner = AreaHandle(x: 1, y: 1), left = AreaHandle(x: -1, y: 0)

    @Test func freeResizeKeepsTheOppositeCornerAndStaysInBounds() {
        #expect(resizing(r, corner, by: CGSize(width: 50, height: 20), aspect: nil, in: bounds) == CGRect(x: 100, y: 100, width: 450, height: 220))
        #expect(resizing(r, corner, by: CGSize(width: 900, height: 900), aspect: nil, in: bounds) == CGRect(x: 100, y: 100, width: 900, height: 700))
        #expect(resizing(r, corner, by: CGSize(width: -1000, height: 0), aspect: nil, in: bounds) == CGRect(x: 100, y: 100, width: 40, height: 200))
        #expect(resizing(r, left, by: CGSize(width: -30, height: 99), aspect: nil, in: bounds) == CGRect(x: 70, y: 100, width: 430, height: 200))
    }

    @Test func presetResizeKeepsItsShape() {
        let wide = resizing(r, corner, by: CGSize(width: 200, height: 0), aspect: 2, in: bounds)
        #expect(wide == CGRect(x: 100, y: 100, width: 600, height: 300))
        // Too big for the room below and right of the anchor: shrunk to fit, still 2:1.
        let big = resizing(r, corner, by: CGSize(width: 2000, height: 0), aspect: 2, in: bounds)
        #expect(big.maxX <= bounds.maxX && big.maxY <= bounds.maxY && abs(big.width / big.height - 2) < 1e-9)
        // An edge keeps the other axis centred.
        let edge = resizing(r, left, by: CGSize(width: -100, height: 0), aspect: 2, in: bounds)
        #expect(edge == CGRect(x: 0, y: 75, width: 500, height: 250))
    }

    @Test func moveAndPlaceStopAtTheEdges() {
        #expect(moving(r, by: CGSize(width: -500, height: 10), in: bounds) == CGRect(x: 0, y: 110, width: 400, height: 200))
        #expect(placing(CGSize(width: 640, height: 360), around: CGPoint(x: 900, y: 50), in: bounds) == CGRect(x: 360, y: 0, width: 640, height: 360))
        #expect(placing(CGSize(width: 1080, height: 100), around: .zero, in: bounds) == nil)
    }
}

@Suite struct InspectorFolding {
    @Test func foldsWhenNarrowAndComesBack() {
        var fit = InspectorFit(), shown = true
        fit.fit(width: 1240, shown: &shown); #expect(shown && !fit.narrow)
        fit.fit(width: 720, shown: &shown); #expect(!shown && fit.narrow)
        // Shown by hand while narrow: resizing within narrow leaves it be.
        shown = true
        fit.fit(width: 760, shown: &shown); #expect(shown)
        fit.fit(width: 1000, shown: &shown); #expect(shown && !fit.narrow)
    }

    @Test func hiddenByHandStaysHidden() {
        var fit = InspectorFit(), shown = false
        fit.fit(width: 720, shown: &shown)
        fit.fit(width: 1240, shown: &shown); #expect(!shown)
    }

    @Test func opensFoldedInANarrowWindow() {
        var fit = InspectorFit(), shown = true
        fit.fit(width: 720, shown: &shown); #expect(!shown)
        fit.fit(width: 900, shown: &shown); #expect(shown)
    }
}

@Suite struct FrameLabel {
    private func size(_ w: Int, _ h: Int) -> OutputSize { OutputSize(contentW: w, contentH: h, x: 0, y: 0, width: w, height: h) }

    @Test func namesCommonShapes() {
        #expect(frameLabel(size(1920, 1080)) == "1920 × 1080 · 16:9")
        #expect(frameLabel(size(2880, 1800)) == "2880 × 1800 · 16:10")
        #expect(frameLabel(size(1080, 1350)) == "1080 × 1350 · 4:5")
        #expect(frameLabel(size(1366, 768)) == "1366 × 768 · 16:9") // within 1%
    }

    @Test func leavesOddShapesAsSize() {
        #expect(frameLabel(size(1234, 567)) == "1234 × 567")
        #expect(frameLabel(size(10, 0)) == "10 × 0")
    }
}

@Suite struct ItemIDs {
    /// Ids follow items in the editor but aren't saved, and older edits without them still load.
    @Test func areLeftOutOfSavedEditsAndMadeWhenRead() throws {
        var e = edits()
        e.zooms = [Zoom(start: 1, end: 3, scale: 2)]
        e.callouts = [Callout(text: "Hi", start: 1, end: 2, x: 0, y: 0)]
        e.allAnnotations = [Annotation(kind: .arrow, start: 1, end: 2, x: 0, y: 0, w: 0.1, h: 0.1)]
        let json = try JSONEncoder().encode(e)
        #expect(!String(decoding: json, as: UTF8.self).contains("\"id\""))
        let back = try JSONDecoder().decode(Edits.self, from: json)
        #expect(back == e) // equal, though the ids are new
        #expect(back.zooms[0].id.uuid != e.zooms[0].id.uuid)
    }

    /// Both pieces of a split are on the timeline at once, so the new one needs an id of its own.
    @Test func splitPiecesGetTheirOwnIDs() {
        var e = edits { $0.zooms = [Zoom(start: 1, end: 5, scale: 2)]; $0.callouts = [Callout(text: "Hi", start: 1, end: 5, x: 0, y: 0)] }
        let first = e.zooms[0].id.uuid
        let split = e.split(at: 3)
        #expect(split)
        #expect(e.zooms.count == 2 && e.zooms[0].id.uuid == first && e.zooms[1].id.uuid != first)
        #expect(e.callouts.count == 2 && e.callouts[0].id.uuid != e.callouts[1].id.uuid)
    }
}

@Suite struct ResetGroup {
    /// Each group's Reset puts back only its own settings, and keeps what was made: zooms, caption lines, the music.
    @Test func putsBackOnlyTheGroupsSettings() {
        let start = defaultEdits(duration: 20, cursor: cursor, hasCamera: true)
        var e = start
        e.padding = 0.2; e.shadow = 0.1; e.backgroundImage = "/tmp/wall.heic"
        e.clickEffect = nil; e.cursorIdleHide = nil; e.cursorStyle = CursorStyle(); e.cursorStyle?.smoothing = 1
        e.camera?.size = 0.4; e.camera?.mirror = false
        var c = Captions(lines: [CaptionLine("hello", start: 1, end: 2)])
        c.visible = false; c.size = 1.5; c.srt = false
        e.captions = c
        e.micVolume = 0.3; e.micCleanup = MicCleanup(); e.micCleanup?.noise = .strong
        e.audio = AudioTrack(path: "/tmp/song.m4a", fileDuration: 60, at: 4, length: 10, volume: 0.2, duck: true)

        let look = e.resetting(.look, to: start)
        #expect(look.padding == start.padding && look.shadow == nil && look.backgroundImage == nil && look.gradient == start.gradient)
        #expect(look.clickEffect == nil) // other groups untouched

        let cursorReset = e.resetting(.cursor, to: start)
        #expect(cursorReset.clickEffect == .ripple && cursorReset.cursorIdleHide == 2 && cursorReset.cursorStyle == nil)
        #expect(cursorReset.zooms == e.zooms && cursorReset.padding == 0.2)

        #expect(e.resetting(.webcam, to: start).camera == CameraStyle())

        let captions = e.resetting(.captions, to: start).captions
        #expect(captions?.lines == c.lines && captions?.visible == false && captions?.size == 1 && captions?.srt == true)

        let sound = e.resetting(.sound, to: start)
        #expect(sound.micVolume == nil && sound.micCleanup == nil)
        #expect(sound.audio?.path == "/tmp/song.m4a" && sound.audio?.at == 4 && sound.audio?.volume == 0.6 && sound.audio?.duck == false)

        // Starting edits reset to themselves, so Reset starts out disabled.
        #expect(SettingsGroup.allCases.allSatisfy { start.resetting($0, to: start) == start })
    }
}

@Suite struct Teaching_ {
    @Test func oneUnseenTipAtATimeAndNoneWhileBusy() {
        var t = Teaching()
        #expect(t.tip(relevant: [.zoom, .captions], busy: false) == .zoom)
        #expect(t.tip(relevant: [.zoom, .captions], busy: true) == nil)
        t.seen.insert(.zoom)
        #expect(t.tip(relevant: [.zoom, .captions], busy: false) == .captions)
        #expect(t.tip(relevant: [.zoom], busy: false) == nil)
        t.tipsOff = true
        #expect(t.tip(relevant: [.split], busy: false) == nil && !t.showsCard)
    }

    @Test func cardShowsForTheFirstRecordingsUntilDoneOrDismissed() {
        var t = Teaching()
        t.opens = Teaching.cardOpens
        #expect(t.showsCard)
        t.opens += 1
        #expect(!t.showsCard)
        t.opens = 1
        t.done = Set(NextStep.allCases)
        #expect(!t.showsCard)
        t.done = []
        t.cardDismissed = true
        #expect(!t.showsCard)
        t.reset()
        #expect(t.showsCard && t == Teaching())
    }

    @Test func keptAndReadBack() {
        var t = Teaching()
        t.seen = [.split]; t.done = [.watch, .export]; t.tipsOff = true; t.cardDismissed = true; t.opens = 2
        #expect(Teaching(stored: t.stored) == t)
        #expect(Teaching(stored: ["seen": ["nonsense", "zoom"], "opens": "x"]).seen == [.zoom])
    }
}

@Suite struct ShortcutOverview {
    @Test func everyBoundShortcutByGroupThenTheMenus() {
        var map = ShortcutMap.defaults
        map[.addMarker] = nil
        let groups = map.overview(tabs: ["Look", "Cursor & Zoom", "Overlays", "Sound"])
        #expect(groups.map(\.title) == ShortcutGroup.allCases.map(\.title) + ["Menus"])
        let all = groups.flatMap(\.items)
        #expect(!all.contains { $0.label == ShortcutAction.addMarker.label })
        #expect(all.contains { $0.label == ShortcutAction.addText.label && $0.shortcut == Shortcut("t") })
        #expect(groups[2].items.last?.shortcut == Shortcut("escape"))
        let menus = groups.last!.items
        #expect(menus.contains { $0.label == "Inspector: Sound" && $0.shortcut == Shortcut("cmd+4") })
        #expect(!menus.contains { $0.label.hasPrefix("Inspector Tab") || $0.shortcut == Shortcut("cmd+5") })
        #expect(menus.map(\.label) == menus.map(\.label).sorted())
    }
}

@Suite struct ReleaseNotes {
    @Test func turnsGitHubNotesIntoInlineMarkdown() {
        let notes = """
        ## What's Changed
        * Fix the timeline by @kasapovicc in https://github.com/kasapovicc/RecordStudio/pull/123
          - nested, see [docs](https://example.com/a) and https://example.com/b
        Not a #hashtag line, *italic* stays.

        **Full Changelog**: https://github.com/kasapovicc/RecordStudio/compare/v0.9.0...v1.0.0
        """
        #expect(releaseNotesMarkdown(notes) == """
        **What's Changed**
        • Fix the timeline by @kasapovicc in [#123](https://github.com/kasapovicc/RecordStudio/pull/123)
          • nested, see [docs](https://example.com/a) and [example.com](https://example.com/b)
        Not a #hashtag line, *italic* stays.

        **Full Changelog**: [v0.9.0...v1.0.0](https://github.com/kasapovicc/RecordStudio/compare/v0.9.0...v1.0.0)
        """)
    }
}
