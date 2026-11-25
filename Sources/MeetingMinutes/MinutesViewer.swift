import AppKit
import SwiftUI

// MARK: - One minutes file

/// A minutes file in the minutes folder, read for the viewer.
struct MinutesDocument: Identifiable, Hashable {
    let url: URL
    let date: Date
    let title: String
    let excerpt: String
    let duration: String?
    let text: String

    var id: URL { url }

    private static let fileDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f
    }()

    /// Every minutes file, newest first.
    static func loadAll() -> [MinutesDocument] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.minutesFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "md" && $0.lastPathComponent.contains("_Meeting") }
            .compactMap(load)
            .sorted { $0.date > $1.date }
    }

    static func load(_ url: URL) -> MinutesDocument? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        let name = url.deletingPathExtension().lastPathComponent
        let date = fileDate.date(from: String(name.prefix(16)))
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let title = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? name

        // The first paragraph under the first section (the summary).
        var excerpt = ""
        if let start = lines.firstIndex(where: { $0.hasPrefix("## ") }) {
            excerpt = lines[(start + 1)...].first { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("#") && !t.hasPrefix(">") && !t.hasPrefix("-")
            } ?? ""
        }
        excerpt = excerpt.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "**", with: "")

        // Duration: the last timestamp of the transcript.
        let lastStamp = lines.reversed().lazy.compactMap { MinutesLine.timestamp(in: $0) }.first
        return MinutesDocument(url: url, date: date, title: title, excerpt: excerpt, duration: lastStamp.flatMap(readableDuration), text: text)
    }

    /// "00:12:30" → "12 min", "01:05:06" → "1h05"; nil under a minute.
    static func readableDuration(_ stamp: String) -> String? {
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let minutes = parts[0] * 60 + parts[1]
        guard minutes >= 1 else { return nil }
        return minutes < 60 ? "\(minutes) min" : String(format: "%dh%02d", minutes / 60, minutes % 60)
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Everything above the transcript (the minutes themselves), for copying.
    var minutesPart: String {
        guard let divider = text.range(of: "\n---\n") else { return text }
        return String(text[..<divider.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Reading the Markdown the app writes

/// One line of a minutes file, in the shapes the app writes (it is not a general Markdown reader).
enum MinutesLine: Hashable {
    case title(String)
    case warning(String)
    case heading(String)
    case task(String, owner: String?)
    case bullet(String)
    case transcript(time: String, speaker: String, text: String)
    case note(String)
    case paragraph(String)
    case divider

    private static let transcriptPattern = try! NSRegularExpression(pattern: #"^\*\*\[(\d{2}:\d{2}:\d{2})\] \[([^\]]+)\]:\*\* ?(.*)$"#)

    static func timestamp(in line: String) -> String? {
        guard line.hasPrefix("**["), line.count > 12 else { return nil }
        let start = line.index(line.startIndex, offsetBy: 3)
        let end = line.index(start, offsetBy: 8)
        let stamp = String(line[start..<end])
        return stamp.allSatisfy { $0.isNumber || $0 == ":" } ? stamp : nil
    }

    static func parse(_ text: String) -> [MinutesLine] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line == "---" { return .divider }
            if line.hasPrefix("# ") { return .title(String(line.dropFirst(2))) }
            if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
            if line.hasPrefix("> ") { return .warning(String(line.dropFirst(2))) }
            if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                let body = String(line.dropFirst(6))
                if let dash = body.range(of: " — ") {
                    let owner = String(body[dash.upperBound...])
                        .replacingOccurrences(of: #"\*\*[^*]+:\*\* ?"#, with: "", options: .regularExpression)
                    return .task(String(body[..<dash.lowerBound]), owner: owner)
                }
                return .task(body, owner: nil)
            }
            if line.hasPrefix("- ") { return .bullet(String(line.dropFirst(2))) }
            let range = NSRange(line.startIndex..., in: line)
            if let match = transcriptPattern.firstMatch(in: line, range: range),
               let time = Range(match.range(at: 1), in: line), let speaker = Range(match.range(at: 2), in: line),
               let body = Range(match.range(at: 3), in: line) {
                return .transcript(time: String(line[time]), speaker: String(line[speaker]), text: String(line[body]))
            }
            if line.hasPrefix("_"), line.hasSuffix("_") { return .note(String(line.dropFirst().dropLast())) }
            return .paragraph(line)
        }
    }
}

// MARK: - The window

/// A small reader for the minutes: the list on the left, the minutes on the right, a search
/// over everything. The files stay plain Markdown in the minutes folder.
@MainActor
final class MinutesViewer {
    static let shared = MinutesViewer()
    private var window: NSWindow?
    private let model = MinutesViewerModel()

    /// Opens the window (selecting `url`, if given) and brings it to the front.
    func show(selecting url: URL? = nil) {
        model.reload(selecting: url)
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "Prosa"
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("ProsaMinutesViewer")
            window.contentMinSize = NSSize(width: 680, height: 420)
            window.contentViewController = NSHostingController(rootView: MinutesViewerView(model: model))
            if !window.setFrameUsingName("ProsaMinutesViewer") { window.center() }
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// New minutes were saved: refresh the list if the window is open.
    func minutesChanged(selecting url: URL? = nil) {
        guard window?.isVisible == true else { return }
        model.reload(selecting: url)
    }
}

@MainActor
final class MinutesViewerModel: ObservableObject {
    @Published var documents: [MinutesDocument] = []
    @Published var selection: URL?
    @Published var query = ""

    var filtered: [MinutesDocument] { documents.filter { $0.matches(query) } }
    var selected: MinutesDocument? { documents.first { $0.url == selection } }

    func reload(selecting url: URL? = nil) {
        documents = MinutesDocument.loadAll()
        if let url { selection = url }
        if selection == nil || !documents.contains(where: { $0.url == selection }) {
            selection = documents.first?.url
        }
    }
}

struct MinutesViewerView: View {
    @ObservedObject var model: MinutesViewerModel

    var body: some View {
        NavigationSplitView {
            List(model.filtered, selection: $model.selection) { doc in
                MinutesRow(doc: doc).tag(doc.url)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
            .overlay {
                if model.documents.isEmpty {
                    ContentUnavailableView("No minutes yet", systemImage: "water.waves",
                                           description: Text("Press the recording shortcut in a meeting. The minutes show up here."))
                } else if model.filtered.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                }
            }
        } detail: {
            if let doc = model.selected {
                MinutesDetail(doc: doc, query: model.query)
            } else {
                ContentUnavailableView("Pick a meeting", systemImage: "doc.text")
            }
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: "Search all minutes")
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.reload()
        }
    }
}

struct MinutesRow: View {
    let doc: MinutesDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(doc.date, format: .dateTime.day().month(.abbreviated).year())
                    .font(.headline)
                Spacer()
                Text(doc.date, format: .dateTime.hour().minute())
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if !doc.excerpt.isEmpty {
                Text(doc.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            if let duration = doc.duration {
                Label(duration, systemImage: "clock").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}

struct MinutesDetail: View {
    let doc: MinutesDocument
    let query: String
    @State private var copied = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(MinutesLine.parse(doc.text).enumerated()), id: \.offset) { _, line in
                    MinutesLineView(line: line, query: query)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(doc.minutesPart, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy Minutes", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy the minutes (without the transcript)")
                Button { NSWorkspace.shared.open(doc.url) } label: {
                    Label("Open File", systemImage: "square.and.pencil")
                }
                .help("Open the .md in your default app")
                Button { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        }
        .navigationTitle(doc.date.formatted(.dateTime.day().month(.wide).year()))
    }
}

struct MinutesLineView: View {
    let line: MinutesLine
    let query: String
    private static let youLabels = MeetingLanguage.youLabels

    var body: some View {
        switch line {
        case let .title(text):
            Text(text).font(.system(.title, design: .default, weight: .bold)).padding(.bottom, 4)
        case let .heading(text):
            Text(text).font(.title3.weight(.semibold)).padding(.top, 14)
        case let .warning(text):
            inline(text)
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        case let .task(text, owner):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "square").foregroundStyle(.secondary)
                inline(text)
                if let owner, !owner.isEmpty {
                    Text(owner).font(.caption.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
            }
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                inline(text)
            }
        case let .transcript(time, speaker, text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(time).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                Text(speaker).font(.caption.weight(.semibold))
                    .foregroundStyle(Self.youLabels.contains(speaker) ? Color.accentColor : Color.secondary)
                    .frame(width: 64, alignment: .leading)
                inline(text)
            }
            .padding(.vertical, 2)
            .background(matchesQuery(text) ? Color.yellow.opacity(0.18) : Color.clear)
        case let .note(text):
            Text(text).italic().foregroundStyle(.secondary)
        case let .paragraph(text):
            inline(text).lineSpacing(3)
        case .divider:
            Divider().padding(.vertical, 10)
        }
    }

    private func matchesQuery(_ text: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return !q.isEmpty && text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Bold and italics inside a line.
    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}
