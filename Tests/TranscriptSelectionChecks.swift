import Foundation

@main struct TranscriptSelectionChecks {
    static func main() {
        let original = "你好😀 English"
        let selected = (original as NSString).range(of: "😀 English")
        precondition(TranscriptSelection.selectedText(in: original, range: selected) == "😀 English")
        precondition(TranscriptSelection.selectedText(in: "你好", range: selected) == nil)
        precondition(TranscriptSelection.selectedText(in: original, range: NSRange(location: NSNotFound, length: 1)) == nil)
        precondition(TranscriptSelection.selectedText(in: original, range: NSRange(location: 0, length: Int.max)) == nil)
        print("PASS: selected text follows the current content and rejects stale ranges")
    }
}
