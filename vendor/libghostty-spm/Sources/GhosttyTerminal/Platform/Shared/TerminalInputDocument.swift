import Foundation

/// The document a text input client presents to the system: `anchorLength`
/// positions that hold no text, then `committedLength` positions of text
/// already sent to the terminal that the system may still rewrite (iOS
/// dictation's running hypothesis), then the marked text. Positions handed
/// to the system are document positions; the marked-text state and the
/// committed tail work in their own offsets, and this is the one place that
/// converts between them.
struct TerminalInputDocument {
    let anchorLength: Int
    var committedLength: Int = 0
    let markedLength: Int

    var length: Int {
        anchorLength + committedLength + markedLength
    }

    private var markedStart: Int {
        anchorLength + committedLength
    }

    /// The document position of an offset into the marked text.
    func position(ofMarkedOffset offset: Int) -> Int {
        markedStart + min(max(offset, 0), markedLength)
    }

    /// The marked-text offset nearest a document position: anything before
    /// the marked text is its start.
    func markedOffset(of position: Int) -> Int {
        min(max(position - markedStart, 0), markedLength)
    }

    /// The part of a document range that lies in the marked text, in
    /// marked-text offsets. The anchor and the committed tail contribute
    /// nothing.
    func markedRange(of range: NSRange) -> NSRange {
        let start = markedOffset(of: range.location)
        let end = max(markedOffset(of: range.location + range.length), start)
        return NSRange(location: start, length: end - start)
    }

    /// The part of a document range that lies in the committed tail, in
    /// tail offsets.
    func committedRange(of range: NSRange) -> NSRange {
        func offset(_ position: Int) -> Int {
            min(max(position - anchorLength, 0), committedLength)
        }
        let start = offset(range.location)
        let end = max(offset(range.location + range.length), start)
        return NSRange(location: start, length: end - start)
    }
}
