import Foundation

enum TranscriptSelection {
    static func selectedText(in text: String, range: NSRange) -> String? {
        let content = text as NSString
        guard range.location != NSNotFound,
              range.length > 0,
              range.location <= content.length,
              range.length <= content.length - range.location else {
            return nil
        }
        return content.substring(with: range)
    }
}
