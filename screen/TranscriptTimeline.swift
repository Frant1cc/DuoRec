import Foundation

struct TranscriptSegment {
    let source: AudioSource?
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

enum TranscriptTimeline {
    static func grouped(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let ordered = segments.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.source == .system && $1.source != .system
        }
        var result: [TranscriptSegment] = []
        for segment in ordered {
            if let previous = result.last,
               previous.source == segment.source,
               segment.startTime <= previous.endTime + 0.75,
               segment.endTime - previous.startTime <= 20 {
                result[result.count - 1] = TranscriptSegment(
                    source: previous.source,
                    startTime: previous.startTime,
                    endTime: max(previous.endTime, segment.endTime),
                    text: previous.text + segment.text
                )
            } else {
                result.append(segment)
            }
        }
        return result
    }
}
