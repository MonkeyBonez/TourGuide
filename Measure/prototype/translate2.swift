// Apple on-device Japanese → English through the Translation framework, which only hands out a
// session via SwiftUI. An AppKit shell with one hosted view; every step goes to a log file.
//   swiftc translate2.swift -o translate2 && ./translate2 in.json out.json log.txt
import AppKit
import SwiftUI
import Translation

let args = CommandLine.arguments
let logURL = URL(fileURLWithPath: args[3])
FileManager.default.createFile(atPath: logURL.path, contents: nil)
func log(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

struct ContentView: View {
    @State private var config: TranslationSession.Configuration? = nil
    @State private var status = "checking…"
    let ja = Locale.Language(identifier: "ja"), en = Locale.Language(identifier: "en")

    var body: some View {
        VStack(spacing: 8) {
            Text("Tour Guide translation test").font(.headline)
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 420, height: 160)
        .task {
            log("view task running")
            let s = await LanguageAvailability().status(from: ja, to: en)
            log("ja→en status: \(s)")
            status = "ja→en \(s); starting session"
            config = .init(source: ja, target: en)
        }
        .translationTask(config) { session in
            log("translation task fired")
            do {
                status = "preparing (download sheet may appear)"
                try await session.prepareTranslation()
                log("prepared")
                let input = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
                let requests = input.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: "\($0.offset)") }
                status = "translating \(input.count) strings"
                let t0 = Date()
                let responses = try await session.translations(from: requests)
                var out = [String](repeating: "", count: input.count)
                for r in responses { if let id = r.clientIdentifier, let i = Int(id) { out[i] = r.targetText } }
                try JSONEncoder().encode(out).write(to: URL(fileURLWithPath: args[2]))
                log("translated \(input.count) strings in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                exit(0)
            } catch {
                log("error: \(error)")
                exit(1)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        log("launched")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "Tour Guide translation test"
        window.contentView = NSHostingView(rootView: ContentView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log("window shown")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
