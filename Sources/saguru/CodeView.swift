import AppKit
import SwiftUI

/// Read-only code with syntax colours and line numbers, for bodies and raw HTTP messages.
/// `filter` keeps only the lines that contain it; each keeps the number it has in the whole text.
struct CodeView: NSViewRepresentable {
    enum Language { case json, http, plain }

    let text: String
    var language = Language.plain
    var filter = ""

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let lineHeight: CGFloat = 18

    final class Coordinator { var shown = "" }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 6, height: 6)
        // Long lines scroll sideways instead of wrapping, so a line number is always one row.
        view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        let ruler = LineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = view
        // Views no longer clip their drawing by default: without this the numbers run over what is below.
        ruler.clipsToBounds = true
        scroll.clipsToBounds = true
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak ruler] _ in
            ruler?.needsDisplay = true
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let key = "\(language)|\(filter)|\(text.count)|\(text.hashValue)"
        guard key != context.coordinator.shown, let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.shown = key

        let wanted = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = Self.lineHeight
        style.maximumLineHeight = Self.lineHeight
        let result = NSMutableAttributedString()
        var numbers: [Int] = []
        var inBody = false
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(line)
            var kind = language
            if language == .http {
                // Start line and headers first; after the empty line comes the body.
                if inBody { kind = .json } else if line.isEmpty { inBody = true }
            }
            if !wanted.isEmpty, !line.lowercased().contains(wanted) { continue }
            if !numbers.isEmpty { result.append(NSAttributedString(string: "\n")) }
            numbers.append(index + 1)
            let start = result.length
            switch kind {
            case .json: Highlight.json(line, into: result)
            case .http: Highlight.http(line, first: index == 0, into: result)
            case .plain: result.append(NSAttributedString(string: line, attributes: [.foregroundColor: Highlight.plain]))
            }
            if !wanted.isEmpty { Highlight.mark(wanted, from: start, in: result) }
        }
        result.addAttributes([.font: Self.font, .paragraphStyle: style], range: NSRange(location: 0, length: result.length))
        view.textStorage?.setAttributedString(result)
        view.scroll(.zero)
        if let ruler = scroll.verticalRulerView as? LineRuler {
            ruler.numbers = numbers
            ruler.ruleThickness = CGFloat(max(String(numbers.last ?? 1).count, 2)) * 8 + 18
            ruler.needsDisplay = true
        }
    }
}

/// The gutter with the line numbers.
final class LineRuler: NSRulerView {
    var numbers: [Int] = []

    override func draw(_ dirtyRect: NSRect) {
        NSColor(red: 0.11, green: 0.11, blue: 0.125, alpha: 1).setFill()
        bounds.fill()
        guard let view = clientView as? NSTextView, let scroll = scrollView else { return }
        let offset = scroll.contentView.bounds.minY
        let top = view.textContainerInset.height
        let height = CodeView.lineHeight
        let first = max(Int((offset - top) / height), 0)
        let last = min(first + Int(bounds.height / height) + 2, numbers.count)
        guard first < last else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.32),
        ]
        for row in first..<last {
            let label = NSAttributedString(string: "\(numbers[row])", attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: bounds.width - size.width - 8, y: top + CGFloat(row) * height - offset + (height - size.height) / 2))
        }
    }
}

enum Highlight {
    static let plain = NSColor(white: 0.88, alpha: 1)
    static let key = NSColor(red: 0.61, green: 0.82, blue: 0.99, alpha: 1)
    static let string = NSColor(red: 0.93, green: 0.62, blue: 0.45, alpha: 1)
    static let number = NSColor(red: 0.71, green: 0.86, blue: 0.62, alpha: 1)
    static let word = NSColor(red: 0.80, green: 0.56, blue: 0.86, alpha: 1)
    static let brace = NSColor(red: 0.95, green: 0.82, blue: 0.38, alpha: 1)
    static let dim = NSColor(white: 0.6, alpha: 1)
    static let verb = NSColor(red: 0.45, green: 0.83, blue: 0.52, alpha: 1)
    static let version = NSColor(red: 0.94, green: 0.48, blue: 0.40, alpha: 1)

    private static func add(_ text: String, _ color: NSColor, to out: NSMutableAttributedString) {
        out.append(NSAttributedString(string: text, attributes: [.foregroundColor: color]))
    }

    /// One line of JSON (or of anything else: what is not JSON simply comes out plain).
    static func json(_ line: String, into out: NSMutableAttributedString) {
        let characters = Array(line)
        var position = 0
        while position < characters.count {
            let character = characters[position]
            if character == "\"" {
                var end = position + 1
                var escaped = false
                while end < characters.count {
                    if escaped { escaped = false } else if characters[end] == "\\" { escaped = true } else if characters[end] == "\"" { break }
                    end += 1
                }
                let stop = min(end + 1, characters.count)
                // A string followed by a colon is a key.
                let next = characters[stop...].first { $0 != " " }
                add(String(characters[position..<stop]), next == ":" ? key : string, to: out)
                position = stop
            } else if character.isNumber || (character == "-" && position + 1 < characters.count && characters[position + 1].isNumber) {
                var end = position + 1
                while end < characters.count, characters[end].isNumber || ".eE+-".contains(characters[end]) { end += 1 }
                add(String(characters[position..<end]), number, to: out)
                position = end
            } else if character.isLetter {
                var end = position + 1
                while end < characters.count, characters[end].isLetter { end += 1 }
                let text = String(characters[position..<end])
                add(text, ["true", "false", "null"].contains(text) ? word : plain, to: out)
                position = end
            } else {
                add(String(character), "{}[]".contains(character) ? brace : (",:".contains(character) ? dim : plain), to: out)
                position += 1
            }
        }
    }

    /// The start line ("GET /ruta HTTP/2", "HTTP/2 200") or a header of a raw HTTP message.
    static func http(_ line: String, first: Bool, into out: NSMutableAttributedString) {
        if first {
            for (index, piece) in line.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                if index > 0 { add(" ", plain, to: out) }
                let text = String(piece)
                add(text, text.hasPrefix("HTTP/") ? version : (index == 0 ? verb : (Int(text) != nil ? number : plain)), to: out)
            }
        } else if let colon = line.firstIndex(of: ":") {
            add(String(line[...colon]), key, to: out)
            add(String(line[line.index(after: colon)...]), plain, to: out)
        } else {
            add(line, plain, to: out)
        }
    }

    /// Paints the filter's matches in the line that was just appended.
    static func mark(_ wanted: String, from start: Int, in out: NSMutableAttributedString) {
        let whole = out.string as NSString
        var search = NSRange(location: start, length: whole.length - start)
        while search.length > 0 {
            let found = whole.range(of: wanted, options: .caseInsensitive, range: search)
            guard found.location != NSNotFound else { break }
            out.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: found)
            search = NSRange(location: found.location + found.length, length: whole.length - found.location - found.length)
        }
    }
}

// MARK: - Editing a response as one HTTP message

/// What a mock is edited as: the response the way it travels. Status line, headers, an empty line, the body.
enum MockDocument {
    static let statuses: [(code: Int, reason: String)] = [
        (200, "OK"), (201, "Created"), (202, "Accepted"), (204, "No Content"), (206, "Partial Content"),
        (301, "Moved Permanently"), (302, "Found"), (304, "Not Modified"), (307, "Temporary Redirect"), (308, "Permanent Redirect"),
        (400, "Bad Request"), (401, "Unauthorized"), (402, "Payment Required"), (403, "Forbidden"), (404, "Not Found"),
        (405, "Method Not Allowed"), (406, "Not Acceptable"), (408, "Request Timeout"), (409, "Conflict"), (410, "Gone"),
        (412, "Precondition Failed"), (413, "Content Too Large"), (415, "Unsupported Media Type"), (418, "I'm a teapot"),
        (422, "Unprocessable Content"), (423, "Locked"), (425, "Too Early"), (426, "Upgrade Required"), (428, "Precondition Required"),
        (429, "Too Many Requests"), (451, "Unavailable For Legal Reasons"),
        (500, "Internal Server Error"), (501, "Not Implemented"), (502, "Bad Gateway"), (503, "Service Unavailable"),
        (504, "Gateway Timeout"), (507, "Insufficient Storage"), (511, "Network Authentication Required"),
    ]

    static let headers = [
        "Access-Control-Allow-Credentials", "Access-Control-Allow-Headers", "Access-Control-Allow-Methods", "Access-Control-Allow-Origin",
        "Age", "Allow", "Cache-Control", "Content-Disposition", "Content-Language", "Content-Location", "Content-Type", "Date", "ETag",
        "Expires", "Last-Modified", "Link", "Location", "Pragma", "RateLimit-Limit", "RateLimit-Remaining", "RateLimit-Reset",
        "Retry-After", "Server", "Set-Cookie", "Strict-Transport-Security", "Vary", "WWW-Authenticate", "X-Request-Id",
    ]

    static let values: [String: [String]] = [
        "content-type": ["application/json", "application/json; charset=utf-8", "application/problem+json", "application/xml",
                         "application/pdf", "application/octet-stream", "application/x-www-form-urlencoded", "text/plain; charset=utf-8",
                         "text/html; charset=utf-8", "text/csv", "image/png", "image/jpeg", "image/webp", "image/svg+xml"],
        "cache-control": ["no-store", "no-cache", "max-age=0", "max-age=3600", "private", "public, max-age=86400"],
        "access-control-allow-origin": ["*"],
        "access-control-allow-credentials": ["true"],
        "retry-after": ["1", "30", "120"],
        "www-authenticate": ["Bearer", "Basic realm=\"api\""],
    ]

    static func reason(_ code: Int) -> String { statuses.first { $0.code == code }?.reason ?? "" }

    static func compose(status: Int, headers: [NetHeader], body: String) -> String {
        var lines = ["HTTP/1.1 \(status) \(reason(status))".trimmingCharacters(in: .whitespaces)]
        lines += headers.map { "\($0.name): \($0.value)" }
        return lines.joined(separator: "\n") + "\n\n" + body
    }

    /// `status` is nil when the first line cannot be read as "HTTP/1.1 200 …".
    static func parse(_ text: String) -> (status: Int?, headers: [(name: String, value: String)], body: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let first = (lines.first ?? "").split(separator: " ")
        var status: Int?
        if first.count >= 2, first[0].uppercased().hasPrefix("HTTP"), let code = Int(first[1]), (100...599).contains(code) { status = code }
        var headers: [(String, String)] = []
        var index = 1
        while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            if let colon = lines[index].firstIndex(of: ":") {
                let name = lines[index][..<colon].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { headers.append((name, lines[index][lines[index].index(after: colon)...].trimmingCharacters(in: .whitespaces))) }
            }
            index += 1
        }
        let body = index + 1 < lines.count ? lines[(index + 1)...].joined(separator: "\n") : ""
        return (status, headers, body)
    }
}

/// An editable HTTP response with colours, line numbers and suggestions for status codes, header names
/// and the usual values of some headers.
struct HTTPEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = CompletingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.insertionPointColor = .white
        view.font = CodeView.font
        // JSON written with typographic quotes or dashes stops being JSON.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.delegate = context.coordinator
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.clipsToBounds = true
        let ruler = LineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = view
        ruler.clipsToBounds = true
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak ruler] _ in
            ruler?.needsDisplay = true
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? CompletingTextView, view.string != text else { return }
        view.string = text
        context.coordinator.restyle(view)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HTTPEditor
        private var typed = false

        init(_ parent: HTTPEditor) { self.parent = parent }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // Suggestions follow typing, not deleting or pasting.
            typed = (replacementString?.count ?? 0) == 1 && replacementString != "\n"
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? CompletingTextView else { return }
            if typed { renameStatus(view) }
            restyle(view)
            parent.text = view.string
            if typed, !view.suggesting, view.suggestions()?.options.isEmpty == false {
                view.suggesting = true
                view.complete(nil)
                view.suggesting = false
            }
            typed = false
        }

        /// Typing a whole status code over another one ("503" → "201") brings the new code's name along.
        private func renameStatus(_ view: NSTextView) {
            let whole = view.string as NSString
            let cursor = view.selectedRange().location
            let line = whole.lineRange(for: NSRange(location: 0, length: 0))
            var end = line.length
            if end > 0, whole.character(at: end - 1) == 10 { end -= 1 }
            guard cursor <= end else { return }
            let pieces = whole.substring(to: cursor).split(separator: " ", omittingEmptySubsequences: false)
            guard pieces.count == 2, pieces[1].count == 3, let code = Int(pieces[1]) else { return }
            let rest = whole.substring(with: NSRange(location: cursor, length: end - cursor)).trimmingCharacters(in: .whitespaces)
            let name = MockDocument.reason(code)
            guard rest != name, rest.isEmpty || MockDocument.statuses.contains(where: { $0.reason == rest }) else { return }
            view.insertText(name.isEmpty ? "" : " " + name, replacementRange: NSRange(location: cursor, length: end - cursor))
            view.setSelectedRange(NSRange(location: cursor, length: 0))
        }

        /// Colours the text in place (the insertion point stays where it is) and renumbers the gutter.
        func restyle(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let text = view.string
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = CodeView.lineHeight
            style.maximumLineHeight = CodeView.lineHeight
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let colored = NSMutableAttributedString()
            if text.utf16.count < 150_000 {
                var inBody = false
                for (index, line) in lines.enumerated() {
                    if index > 0 { colored.append(NSAttributedString(string: "\n")) }
                    let line = String(line)
                    if inBody { Highlight.json(line, into: colored) } else {
                        Highlight.http(line, first: index == 0, into: colored)
                        if line.isEmpty, index > 0 { inBody = true }
                    }
                }
            }
            storage.beginEditing()
            let whole = NSRange(location: 0, length: storage.length)
            storage.setAttributes([.font: CodeView.font, .paragraphStyle: style, .foregroundColor: Highlight.plain], range: whole)
            if colored.length == storage.length {
                colored.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
                    if let value { storage.addAttribute(.foregroundColor, value: value, range: range) }
                }
            }
            storage.endEditing()
            view.typingAttributes = [.font: CodeView.font, .paragraphStyle: style, .foregroundColor: Highlight.plain]
            if let ruler = view.enclosingScrollView?.verticalRulerView as? LineRuler {
                ruler.numbers = Array(1...max(lines.count, 1))
                ruler.ruleThickness = CGFloat(max(String(lines.count).count, 2)) * 8 + 18
                ruler.needsDisplay = true
            }
        }
    }
}

final class CompletingTextView: NSTextView {
    var suggesting = false

    /// What can be suggested where the insertion point is, and the stretch of text a choice replaces.
    func suggestions() -> (range: NSRange, options: [String])? {
        let whole = string as NSString
        let cursor = selectedRange().location
        guard selectedRange().length == 0 || suggesting, cursor <= whole.length else { return nil }
        let line = whole.lineRange(for: NSRange(location: cursor, length: 0))
        var lineEnd = line.location + line.length
        if lineEnd > line.location, whole.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
        let before = whole.substring(with: NSRange(location: line.location, length: cursor - line.location))

        if line.location == 0 {
            // "HTTP/1.1 4" → the status codes that start with 4, or whose name contains what was typed.
            guard let space = before.firstIndex(of: " ") else { return nil }
            let typed = before[before.index(after: space)...].lowercased()
            let start = before.distance(from: before.startIndex, to: space) + 1
            let options = MockDocument.statuses.map { "\($0.code) \($0.reason)" }
                .filter { typed.isEmpty || $0.lowercased().hasPrefix(typed) || (typed.count > 1 && Int(typed) == nil && $0.lowercased().contains(typed)) }
            return (NSRange(location: start, length: cursor - start), options)
        }
        // Past the first empty line it is the body: nothing to suggest.
        if whole.substring(to: line.location).contains("\n\n") { return nil }
        if let colon = before.firstIndex(of: ":") {
            let name = before[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let rest = before[before.index(after: colon)...]
            let typed = rest.trimmingCharacters(in: .whitespaces).lowercased()
            let start = cursor - (rest.count - (rest.count - rest.drop { $0 == " " }.count))
            let options = (MockDocument.values[name] ?? []).filter { typed.isEmpty || ($0.lowercased().hasPrefix(typed) && $0.lowercased() != typed) }
            return (NSRange(location: start, length: cursor - start), options)
        }
        let typed = before.lowercased()
        guard !typed.isEmpty, !typed.contains(" ") else { return nil }
        let options = MockDocument.headers.filter { $0.lowercased().hasPrefix(typed) }.map { $0 + ": " }
        return (NSRange(location: line.location, length: cursor - line.location), options)
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        // A chosen status brings its name with it, so whatever was left of the old one goes.
        guard flag, MockDocument.statuses.contains(where: { "\($0.code) \($0.reason)" == word }) else { return }
        let whole = string as NSString
        let cursor = selectedRange().location
        let line = whole.lineRange(for: NSRange(location: cursor, length: 0))
        guard line.location == 0 else { return }
        var end = line.length
        if end > 0, whole.character(at: end - 1) == 10 { end -= 1 }
        if end > cursor { insertText("", replacementRange: NSRange(location: cursor, length: end - cursor)) }
    }

    override var rangeForUserCompletion: NSRange {
        suggestions()?.range ?? NSRange(location: NSNotFound, length: 0)
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        // Nothing is chosen until the user picks: typing on never gets replaced by a guess.
        index.pointee = -1
        return suggestions()?.options
    }
}
