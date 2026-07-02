//
//  ChapterSegmentLayout.swift
//  Rivulet
//
//  Pure geometry for the 2a chaptered filmstrip: chapter-proportional
//  segments separated by fixed gaps, plus a piecewise time↔x mapping used
//  for positioning strip overlays (playhead line, live line, dim width,
//  chapter chip, playhead thread). Positions that land inside a gap snap
//  to the nearest segment edge.
//
//  No app/view state — safe to construct on every strip layout pass.
//

import UIKit

struct ChapterSegmentLayout {

    struct Segment {
        let rect: CGRect
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    let segments: [Segment]
    private let width: CGFloat

    init(chapters: [PlexChapter], duration: TimeInterval, width: CGFloat, height: CGFloat, gap: CGFloat) {
        self.width = width
        // Build (start, end) ranges in seconds from the chapter list. Plex
        // sometimes omits the leading chapter boundary (first chapter
        // doesn't start at 0) — insert an implicit leading segment so the
        // strip still covers the full duration from 0.
        var boundaries = chapters.compactMap { chapter -> TimeInterval? in
            guard let startMs = chapter.startTimeOffset else { return nil }
            return TimeInterval(startMs) / 1000.0
        }
        var ranges: [(start: TimeInterval, end: TimeInterval)] = []

        if duration > 0 && !boundaries.isEmpty {
            boundaries.sort()
            if boundaries.first! > 0 {
                boundaries.insert(0, at: 0)
            }
            for (i, start) in boundaries.enumerated() {
                let end = i + 1 < boundaries.count ? boundaries[i + 1] : duration
                if end > start {
                    ranges.append((start, end))
                }
            }
        }
        if ranges.isEmpty {
            ranges = [(0, max(duration, 1))]
        }

        let totalGap = gap * CGFloat(ranges.count - 1)
        let usable = max(0, width - totalGap)
        let total = ranges.reduce(0) { $0 + ($1.end - $1.start) }
        var x: CGFloat = 0
        var segments: [Segment] = []
        for range in ranges {
            let w = total > 0 ? usable * CGFloat((range.end - range.start) / total) : usable
            segments.append(Segment(rect: CGRect(x: x, y: 0, width: w, height: height),
                                     startTime: range.start, endTime: range.end))
            x += w + gap
        }
        self.segments = segments
    }

    /// Maps a playback time to an x position on the strip. Times inside a
    /// segment interpolate linearly across that segment's rect; times that
    /// fall past the end of the timeline clamp to the last segment's
    /// trailing edge (which is where a gap would otherwise leave x
    /// undefined).
    func x(for time: TimeInterval) -> CGFloat {
        for segment in segments where time <= segment.endTime {
            let span = segment.endTime - segment.startTime
            guard span > 0 else { return segment.rect.minX }
            let fraction = max(0, (time - segment.startTime) / span)
            return segment.rect.minX + segment.rect.width * CGFloat(min(1, fraction))
        }
        return segments.last?.rect.maxX ?? width
    }

    /// Maps an x position on the strip back to a playback time. Positions
    /// that land inside an inter-segment gap snap to the nearest segment
    /// edge (the segment whose rect first reaches past x).
    func time(for x: CGFloat) -> TimeInterval {
        for segment in segments {
            if x <= segment.rect.maxX {
                let clamped = max(segment.rect.minX, x)
                guard segment.rect.width > 0 else { return segment.startTime }
                let fraction = (clamped - segment.rect.minX) / segment.rect.width
                return segment.startTime + (segment.endTime - segment.startTime) * TimeInterval(fraction)
            }
        }
        return segments.last?.endTime ?? 0
    }
}
