import Foundation

@main struct TranscriptTimelineChecks {
    static func main() {
        let outOfOrder = [
            TranscriptSegment(source: .microphone, startTime: 3.0, endTime: 3.6, text: "好的"),
            TranscriptSegment(source: .system, startTime: 0.0, endTime: 1.0, text: "你好"),
            TranscriptSegment(source: .system, startTime: 1.0, endTime: 2.0, text: "，请回答"),
            TranscriptSegment(source: .microphone, startTime: 3.6, endTime: 4.2, text: "，收到"),
            TranscriptSegment(source: .system, startTime: 3.4, endTime: 3.8, text: "还有一点")
        ]

        let grouped = TranscriptTimeline.grouped(outOfOrder)
        precondition(grouped.count == 4)
        precondition(grouped[0].source == .system && grouped[0].text == "你好，请回答")
        precondition(grouped[1].source == .microphone && grouped[1].startTime == 3.0)
        precondition(grouped[2].source == .system && grouped[2].startTime == 3.4)
        precondition(grouped[3].source == .microphone && grouped[3].startTime == 3.6)
        print("PASS: source turns are grouped and ordered on one timeline")
    }
}
