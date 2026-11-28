// DesktopNote — sticky notes that live on your wallpaper.
// Everything is saved automatically to ~/Desktop/life/stickers.json

import Cocoa
import UniformTypeIdentifiers
import UserNotifications
import WebKit

let lifeDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/life")
let storeURL = lifeDir.appendingPathComponent("stickers.json")
let oldNotesURL = lifeDir.appendingPathComponent("notes.txt")
let wallpaperDir = lifeDir.appendingPathComponent("wallpapers")
let feedsURL = lifeDir.appendingPathComponent("feeds.json")

// Sticker paper colours: yellow, pink, blue, green, purple, orange
let palette: [NSColor] = [
    NSColor(srgbRed: 1.00, green: 0.93, blue: 0.55, alpha: 1),
    NSColor(srgbRed: 1.00, green: 0.76, blue: 0.83, alpha: 1),
    NSColor(srgbRed: 0.69, green: 0.85, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.74, green: 0.93, blue: 0.72, alpha: 1),
    NSColor(srgbRed: 0.85, green: 0.77, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 1.00, green: 0.82, blue: 0.62, alpha: 1),
]
// Text/icon colour — switches between white (dark style) and near-black (light style).
var inkColor = NSColor.white
let darkInk = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.95)

// Is the current wallpaper mostly bright? Shrinks it to 16×16 and averages the brightness.
func wallpaperIsLight() -> Bool {
    guard let screen = NSScreen.main,
          let url = NSWorkspace.shared.desktopImageURL(for: screen),
          let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary)
    else { return false }
    let n = 16
    var px = [UInt8](repeating: 0, count: n * n * 4)
    let ok: Bool = px.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
        return true
    }
    guard ok else { return false }
    var sum = 0.0
    for i in stride(from: 0, to: px.count, by: 4) {
        sum += 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])
    }
    return sum / Double(n * n) / 255 > 0.55
}
// Handwriting fonts built into macOS: (menu title, font name, size that looks right)
let fontChoices: [(String, String, CGFloat)] = [
    ("Noteworthy — neat handwriting", "Noteworthy-Light", 19),
    ("Bradley Hand — pen writing", "BradleyHandITCTT-Bold", 20),
    ("Chalkboard — casual", "ChalkboardSE-Light", 18),
    ("Marker Felt — marker pen", "MarkerFelt-Thin", 19),
    ("Snell Roundhand — joined-up cursive", "SnellRoundhand", 23),
    ("Plain (no handwriting)", "system", 18),
]
func makeFont(_ name: String) -> NSFont {
    let size = fontChoices.first { $0.1 == name }?.2 ?? 19
    return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
}
var stickerFontName = UserDefaults.standard.string(forKey: "stickerFont") ?? "Noteworthy-Light"
var stickerFont = makeFont(stickerFontName)
// How see-through the stickers are: 0 = fully clear, 1 = solid frosted glass.
let glassOpacity: CGFloat = 0.4
let stickerLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

struct StickerData: Codable {
    var id: String = UUID().uuidString
    var text: String = ""
    var x: Double, y: Double, w: Double, h: Double
    var color: Int = 0
    var remindAt: Double? = nil      // reminder time (seconds since 1970), nil = no reminder
    var agentSession: String? = nil  // this sticker's Claude conversation (Claude Code session id)
    var chat: [ChatLine]? = nil      // the conversation as shown in its chat window
    var frame: NSRect {
        get { NSRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }
}

struct ChatLine: Codable {
    var role: String                 // "user", "claude" or "error"
    var text: String
}

// MARK: - Window that can take keyboard focus even without a title bar

final class StickerWindow: NSWindow {
    var onMouseDown: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onMouseDown?() }
        if event.type == .leftMouseDown && !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        super.sendEvent(event)
    }
}

// MARK: - Top strip: drag it to move the sticker

final class DragBar: NSView {
    var onDrop: (() -> Void)?
    var showsPill = true
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event); onDrop?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        guard showsPill else { return }
        let w: CGFloat = 40, h: CGFloat = 5
        let r = NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        inkColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
    }
}

// MARK: - Bottom-right corner: drag it to resize

final class ResizeGrip: NSView {
    var onDone: (() -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        inkColor.withAlphaComponent(0.3).setStroke()
        for i in 1...3 {
            let p = NSBezierPath(), o = CGFloat(i) * 4
            p.move(to: NSPoint(x: bounds.maxX - o - 3, y: 3))
            p.line(to: NSPoint(x: bounds.maxX - 3, y: o + 3))
            p.lineWidth = 1.2
            p.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        let start = win.frame, startMouse = NSEvent.mouseLocation
        while let e = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), e.type != .leftMouseUp {
            let m = NSEvent.mouseLocation
            var f = start
            f.size.width = max(120, start.width + (m.x - startMouse.x))
            f.size.height = max(70, start.height - (m.y - startMouse.y))
            f.origin.y = start.maxY - f.size.height
            win.setFrame(f, display: true)
        }
        onDone?()
    }
}

// MARK: - Text view with a placeholder when empty

final class StickerTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let pad = textContainer?.lineFragmentPadding ?? 0
        ("Write here…" as NSString).draw(
            at: NSPoint(x: textContainerInset.width + pad, y: textContainerInset.height),
            withAttributes: [.font: stickerFont, .foregroundColor: inkColor.withAlphaComponent(0.4)])
    }
}

// MARK: - Claude on stickers
// The ✨ button on a sticker opens a small chat window beside it. Questions go to Claude through
// the Claude Code you're logged in to. Every sticker keeps its own conversation, so follow-up
// questions remember earlier ones.

let agentDir = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/DesktopNote/agent")

let agentSystemPrompt = """
You are attached to a sticky note on the user's Mac desktop and chat with them in a small window \
beside it. Each message includes what the note currently says, so you can help with it. \
Reply in plain text only: no Markdown (no asterisks, #, tables or code fences); for a list, start \
lines with "•". Keep replies short and to the point, a few lines, unless the user asks for more. \
Use web search when the question needs current information.
"""

private var claudePath: String?
func findClaude() -> String? {
    if let p = claudePath { return p }
    let home = NSHomeDirectory()
    for p in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
              "\(home)/.claude/local/claude"] where FileManager.default.isExecutableFile(atPath: p) {
        claudePath = p
        return p
    }
    // Last resort: ask a login shell, which has the user's full PATH.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "command -v claude"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    claudePath = s.hasPrefix("/") ? s : nil
    return claudePath
}

/// Runs `claude -p` in the background. Calls back on the main thread with the answer and the
/// session id to resume next time, or an error message.
func askClaude(_ prompt: String, session: String?,
               done: @escaping (_ answer: String?, _ session: String?, _ error: String?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        func finish(_ a: String?, _ s: String?, _ e: String?) { DispatchQueue.main.async { done(a, s, e) } }
        guard let claude = findClaude() else {
            return finish(nil, nil, "Claude Code isn't installed (couldn't find the claude command).")
        }
        try? FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.currentDirectoryURL = agentDir
        var args = ["-p", "--output-format", "json",
                    "--setting-sources", "project", "--strict-mcp-config",   // skip your plugins, hooks and MCP servers
                    "--tools", "WebSearch,WebFetch",                         // it can look things up, nothing else
                    "--allowedTools", "WebSearch", "WebFetch",
                    "--append-system-prompt", agentSystemPrompt]
        if let s = session { args += ["--resume", s] }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["USER"] = env["USER"] ?? NSUserName()
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env

        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        do { try p.run() } catch { return finish(nil, nil, "Couldn't start Claude: \(error.localizedDescription)") }

        var errData = Data()
        let errRead = DispatchGroup()
        errRead.enter()
        DispatchQueue.global().async { errData = errors.fileHandleForReading.readDataToEndOfFile(); errRead.leave() }

        // Give up after 4 minutes.
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) { if p.isRunning { p.terminate() } }

        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        errRead.wait()

        let json = (try? JSONSerialization.jsonObject(with: outData)) as? [String: Any]
        let result = (json?["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSession = json?["session_id"] as? String ?? session
        if p.terminationReason == .uncaughtSignal { return finish(nil, nil, "Claude took too long — ask again.") }
        if let r = result, !r.isEmpty, json?["is_error"] as? Bool != true {
            return finish(r, newSession, nil)
        }
        // The saved conversation is gone (e.g. deleted): start a fresh one.
        let raw = (String(data: outData, encoding: .utf8) ?? "") + (String(data: errData, encoding: .utf8) ?? "")
        if session != nil, raw.contains("No conversation found") {
            askClaude(prompt, session: nil, done: done)
            return
        }
        let errText = String(data: errData, encoding: .utf8)?
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        finish(nil, nil, result.flatMap { $0.isEmpty ? nil : $0 } ?? errText ?? "Claude didn't answer (exit \(p.terminationStatus)).")
    }
}

/// Tidies Claude's reply for the chat window: no Markdown symbols, no double blank lines.
func cleanAnswer(_ text: String) -> String {
    var lines: [String] = []
    for raw in text.replacingOccurrences(of: "**", with: "").components(separatedBy: .newlines) {
        var l = raw.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "• " + l.dropFirst(2) }
        while l.hasPrefix("#") { l.removeFirst() }
        l = l.trimmingCharacters(in: .whitespaces)
        if l.isEmpty && (lines.last?.isEmpty ?? true) { continue }   // no double blank lines
        lines.append(l)
    }
    while lines.last?.isEmpty == true { lines.removeLast() }
    return lines.isEmpty ? "(no answer)" : lines.joined(separator: "\n")
}

// MARK: - Chat window (opens beside a sticker from its ✨ button)

final class ChatPanel: NSObject, NSTextFieldDelegate {
    unowned let sticker: Sticker
    let window: StickerWindow
    let paper = NSView()
    let glass = NSVisualEffectView()
    let transcript = NSTextView(frame: .zero)
    let input = NSTextField()
    let inputBox = NSView()
    let titleLabel = NSTextField(labelWithString: "Claude")
    var buttons: [NSButton] = []
    static let width: CGFloat = 330

    init(sticker: Sticker) {
        self.sticker = sticker
        window = StickerWindow(contentRect: NSRect(x: 0, y: 0, width: ChatPanel.width, height: 420),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                         target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func build() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.level = stickerLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        paper.wantsLayer = true
        paper.layer?.cornerRadius = 10
        paper.layer?.masksToBounds = true
        window.contentView = paper
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.frame = paper.bounds
        glass.autoresizingMask = [.width, .height]
        paper.addSubview(glass)

        // Header: drag it to move the chat; ✨ Claude on the left, new chat and close on the right.
        let header = DragBar()
        header.showsPill = false
        header.translatesAutoresizingMaskIntoConstraints = false
        paper.addSubview(header)
        titleLabel.stringValue = "✨ Claude"
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        let close = iconButton("xmark", "Close", #selector(closeChat))
        let fresh = iconButton("square.and.pencil", "New conversation", #selector(newConversation))
        let send = iconButton("arrow.up.circle.fill", "Send", #selector(sendMessage))
        buttons = [close, fresh, send]
        header.addSubview(close)
        header.addSubview(fresh)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        paper.addSubview(scroll)
        transcript.drawsBackground = false
        transcript.isEditable = false
        transcript.isSelectable = true          // so you can copy an answer
        transcript.textContainerInset = NSSize(width: 10, height: 6)
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        scroll.documentView = transcript

        inputBox.wantsLayer = true
        inputBox.layer?.cornerRadius = 9
        inputBox.layer?.borderWidth = 1
        inputBox.translatesAutoresizingMaskIntoConstraints = false
        paper.addSubview(inputBox)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = .systemFont(ofSize: 13)
        input.cell?.isScrollable = true
        input.cell?.wraps = false
        input.delegate = self
        input.translatesAutoresizingMaskIntoConstraints = false
        inputBox.addSubview(input)
        inputBox.addSubview(send)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: paper.topAnchor),
            header.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            fresh.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -14),
            fresh.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: inputBox.topAnchor, constant: -8),

            inputBox.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 10),
            inputBox.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -10),
            inputBox.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -10),
            inputBox.heightAnchor.constraint(equalToConstant: 34),
            input.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor, constant: 10),
            input.centerYAnchor.constraint(equalTo: inputBox.centerYAnchor),
            input.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -6),
            send.trailingAnchor.constraint(equalTo: inputBox.trailingAnchor, constant: -7),
            send.centerYAnchor.constraint(equalTo: inputBox.centerYAnchor),
        ])
        applyTheme()
    }

    func applyTheme() {
        let light = sticker.board.lightStyle
        glass.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        glass.material = light ? .popover : .hudWindow
        glass.alphaValue = light ? 0.85 : 0.8      // a bit less see-through than a sticker, so answers are easy to read
        paper.layer?.borderWidth = 1.5
        paper.layer?.borderColor = (light ? NSColor(srgbRed: 0.80, green: 0.62, blue: 0.18, alpha: 1)    // gold, a touch deeper on light wallpapers
                                          : NSColor(srgbRed: 0.93, green: 0.76, blue: 0.33, alpha: 1)).cgColor
        titleLabel.textColor = inkColor.withAlphaComponent(0.85)
        buttons.forEach { $0.contentTintColor = inkColor.withAlphaComponent(0.55) }
        buttons.last?.contentTintColor = inkColor.withAlphaComponent(0.8)   // send
        inputBox.layer?.backgroundColor = inkColor.withAlphaComponent(0.07).cgColor
        inputBox.layer?.borderColor = inkColor.withAlphaComponent(0.15).cgColor
        input.textColor = inkColor
        input.placeholderAttributedString = NSAttributedString(string: "Ask Claude…", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: inkColor.withAlphaComponent(0.4)])
        (input.currentEditor() as? NSTextView)?.insertionPointColor = inkColor
        render()
    }

    /// Redraws the conversation and scrolls to the newest message.
    func render() {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 13.5)
        let label = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let text = NSMutableParagraphStyle()
        text.lineSpacing = 2
        func add(name: String, _ msg: String, color: NSColor, first: Bool) {
            let head = NSMutableParagraphStyle()
            head.paragraphSpacingBefore = first ? 2 : 14
            head.paragraphSpacing = 2
            out.append(NSAttributedString(string: name + "\n", attributes: [
                .font: label, .foregroundColor: inkColor.withAlphaComponent(0.5), .paragraphStyle: head]))
            out.append(NSAttributedString(string: msg + "\n", attributes: [
                .font: body, .foregroundColor: color, .paragraphStyle: text]))
        }
        let lines = sticker.data.chat ?? []
        for (i, l) in lines.enumerated() {
            add(name: l.role == "user" ? "You" : "Claude", l.text,
                color: l.role == "error" ? .systemOrange : inkColor, first: i == 0)
        }
        if sticker.asking {
            add(name: "Claude", "thinking…", color: inkColor.withAlphaComponent(0.45), first: lines.isEmpty)
        } else if lines.isEmpty {
            out.append(NSAttributedString(string: "Ask me anything. I can see what's written on this sticker, and I'll remember this conversation.", attributes: [
                .font: body, .foregroundColor: inkColor.withAlphaComponent(0.5), .paragraphStyle: text]))
        }
        transcript.textStorage?.setAttributedString(out)
        transcript.scrollToEndOfDocument(nil)
    }

    /// Next to the sticker (right side, or left if there's no room), top edges lined up.
    func place() {
        let s = sticker.window.frame
        guard let vf = (sticker.window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let w = ChatPanel.width, h = min(max(s.height, 420), vf.height)
        var x = s.maxX + 8
        if x + w > vf.maxX { x = s.minX - 8 - w }
        x = max(vf.minX, min(x, vf.maxX - w))
        let y = max(vf.minY, min(s.maxY - h, vf.maxY - h))
        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    var isOpen: Bool { window.isVisible }

    func show() {
        place()
        render()
        window.orderFrontRegardless()
        sticker.window.addChildWindow(window, ordered: .above)   // moves along with the sticker
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
    }

    @objc func closeChat() {
        sticker.window.removeChildWindow(window)
        window.orderOut(nil)
    }

    @objc func sendMessage() {
        let q = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        input.stringValue = ""
        sticker.ask(q)
    }

    @objc func newConversation() {
        guard !sticker.asking else { NSSound.beep(); return }
        sticker.data.chat = []
        sticker.data.agentSession = nil
        sticker.board.scheduleSave()
        render()
        window.makeFirstResponder(input)
    }

    // Enter sends, Esc closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { sendMessage(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { closeChat(); return true }
        return false
    }
}

// MARK: - Reminder picker (opens from the bell button)

let reminderFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    f.doesRelativeDateFormatting = true    // "Today, 15:00" / "Tomorrow, 09:00"
    return f
}()

final class ReminderPicker: NSViewController {
    var onSet: ((Date) -> Void)?
    var onClear: (() -> Void)?
    private let initial: Date
    private let hasReminder: Bool
    private let cal = NSDatePicker()
    private let time = NSDatePicker()
    private let msg = NSTextField(labelWithString: "")

    init(date: Date, hasReminder: Bool) {
        initial = date
        self.hasReminder = hasReminder
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: "Set a reminder")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Pick the day and time to be reminded.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        // Calendar without the heavy blue frame, centred.
        cal.datePickerStyle = .clockAndCalendar
        cal.datePickerElements = .yearMonthDay
        cal.dateValue = initial
        cal.minDate = Calendar.current.startOfDay(for: Date())
        cal.isBezeled = false
        cal.drawsBackground = false
        cal.focusRingType = .none

        // Time row: "Time" on the left, a larger time field on the right.
        let timeLabel = NSTextField(labelWithString: "Time")
        timeLabel.font = .systemFont(ofSize: 14, weight: .medium)
        time.datePickerStyle = .textFieldAndStepper
        time.datePickerElements = .hourMinute
        time.dateValue = initial
        time.controlSize = .large
        time.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        let timeSpacer = NSView()
        timeSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let timeRow = NSStackView(views: [timeLabel, timeSpacer, time])

        msg.textColor = .systemRed
        msg.font = .systemFont(ofSize: 12)
        msg.isHidden = true

        let line = NSBox()
        line.boxType = .separator

        let set = NSButton(title: "Set reminder", target: self, action: #selector(setTapped))
        set.keyEquivalent = "\r"
        set.controlSize = .large
        var bottom: [NSView] = []
        if hasReminder {
            let remove = NSButton(title: "Remove", target: self, action: #selector(clearTapped))
            remove.controlSize = .large
            bottom.append(remove)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottom += [spacer, set]
        let bottomRow = NSStackView(views: bottom)
        bottomRow.spacing = 10

        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3

        let stack = NSStackView(views: [header, cal, timeRow, msg, line, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(18, after: header)
        stack.setCustomSpacing(20, after: cal)
        stack.setCustomSpacing(20, after: timeRow)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 20, right: 22)
        stack.widthAnchor.constraint(equalToConstant: 320).isActive = true
        for row in [header, timeRow, msg, line, bottomRow] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }
        view = stack
    }

    @objc func setTapped() {
        let c = Calendar.current
        var comps = c.dateComponents([.year, .month, .day], from: cal.dateValue)
        let t = c.dateComponents([.hour, .minute], from: time.dateValue)
        comps.hour = t.hour
        comps.minute = t.minute
        comps.second = 0
        guard let d = c.date(from: comps), d > Date() else {
            msg.stringValue = "That time has already passed — pick a later one."
            msg.isHidden = false
            return
        }
        onSet?(d)
    }

    @objc func clearTapped() { onClear?() }
}

// MARK: - One sticker

final class Sticker: NSObject, NSTextViewDelegate, NSWindowDelegate, NSPopoverDelegate {
    var data: StickerData
    let window: StickerWindow
    let paper = NSView()
    let glass = NSVisualEffectView()
    let textView = StickerTextView(frame: .zero)
    unowned let board: Board
    var chrome: [NSView] = []        // top bar (+, drag pill, ×) and resize corner
    var chromeVisible = false
    var buttons: [NSButton] = []
    var bell: NSButton!
    let reminderLabel = NSTextField(labelWithString: "")
    var popover: NSPopover?
    var ringing = false
    var soundTimer: Timer?

    init(_ data: StickerData, board: Board) {
        self.data = data
        self.board = board
        window = StickerWindow(contentRect: data.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                         target: self, action: action)
        b.isBordered = false
        b.contentTintColor = inkColor.withAlphaComponent(0.5)
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func build() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = stickerLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.delegate = self

        // Frosted glass, same look as the original note.
        paper.wantsLayer = true
        paper.layer?.cornerRadius = 8
        paper.layer?.masksToBounds = true
        window.contentView = paper
        // The glass sits behind the text and is faded, so the wallpaper shows through
        // while the writing itself stays fully bright.
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.alphaValue = glassOpacity
        glass.frame = paper.bounds
        glass.autoresizingMask = [.width, .height]
        paper.addSubview(glass)

        let bar = DragBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        paper.addSubview(bar)

        let add = iconButton("plus", "New sticker", #selector(newSticker))
        let delete = iconButton("xmark", "Delete sticker", #selector(deleteMe))
        bell = iconButton("bell", "Set a reminder", #selector(openReminder))
        let claude = iconButton("sparkles", "Ask Claude", #selector(toggleChat))
        buttons = [add, bell, claude, delete]
        buttons.forEach(bar.addSubview)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        paper.addSubview(scroll)

        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = stickerFont
        textView.textColor = inkColor
        let shadow = NSShadow()   // soft shadow keeps text readable on bright wallpapers
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        textView.shadow = shadow
        textView.insertionPointColor = inkColor
        textView.textContainerInset = NSSize(width: 14, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = data.text
        textView.delegate = self
        scroll.documentView = textView

        let grip = ResizeGrip()
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.onDone = { [weak self] in self?.keepOnScreen() }
        bar.onDrop = { [weak self] in self?.keepOnScreen() }
        paper.addSubview(grip)

        // Shows the reminder time at the bottom (always visible when a reminder is set).
        reminderLabel.font = .systemFont(ofSize: 11, weight: .medium)
        reminderLabel.lineBreakMode = .byTruncatingTail
        reminderLabel.alignment = .center
        reminderLabel.translatesAutoresizingMaskIntoConstraints = false
        paper.addSubview(reminderLabel)
        window.onMouseDown = { [weak self] in self?.stopRinging() }

        // Controls stay hidden until you click the sticker.
        chrome = [bar, grip]
        chrome.forEach { $0.isHidden = true }

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: paper.topAnchor),
            bar.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 26),

            add.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            add.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            bell.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 12),
            bell.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            claude.leadingAnchor.constraint(equalTo: bell.trailingAnchor, constant: 12),
            claude.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            delete.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            delete.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -18),

            grip.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -3),
            grip.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -3),
            grip.widthAnchor.constraint(equalToConstant: 16),
            grip.heightAnchor.constraint(equalToConstant: 16),

            reminderLabel.centerXAnchor.constraint(equalTo: paper.centerXAnchor),
            reminderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: paper.leadingAnchor, constant: 22),
            reminderLabel.trailingAnchor.constraint(lessThanOrEqualTo: paper.trailingAnchor, constant: -22),
            reminderLabel.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -3),
        ])

        applyTheme()
        window.orderFrontRegardless()
        keepOnScreen()
    }

    // Light style for bright wallpapers, dark style for dark ones.
    func applyTheme() {
        let light = board.lightStyle
        glass.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        glass.material = light ? .popover : .hudWindow
        glass.alphaValue = light ? 0.6 : glassOpacity
        paper.layer?.borderWidth = 1
        paper.layer?.borderColor = (light ? NSColor.black.withAlphaComponent(0.10)
                                          : NSColor.white.withAlphaComponent(0.08)).cgColor
        textView.font = stickerFont
        textView.textColor = inkColor
        textView.insertionPointColor = inkColor
        let shadow = NSShadow()
        shadow.shadowColor = light ? NSColor.white.withAlphaComponent(0.7) : NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = light ? 2 : 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        textView.shadow = shadow
        buttons.forEach { $0.contentTintColor = inkColor.withAlphaComponent(0.5) }
        updateReminderLabel()
        chatPanel?.applyTheme()
        chrome.forEach { $0.needsDisplay = true }
        textView.needsDisplay = true
    }

    // Never let a sticker hide its top bar under the menu bar or slide off the edge.
    func keepOnScreen() {
        var f = window.frame
        let screen = NSScreen.screens.max { a, b in
            a.visibleFrame.intersection(f).width * a.visibleFrame.intersection(f).height <
            b.visibleFrame.intersection(f).width * b.visibleFrame.intersection(f).height
        } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        f.size.height = min(f.height, vf.height)
        f.size.width = min(f.width, vf.width)
        f.origin.y = min(f.origin.y, vf.maxY - f.height)            // top bar stays below the menu bar
        f.origin.y = max(f.origin.y, vf.minY - f.height + 60)       // at least 60pt visible at bottom
        f.origin.x = max(f.origin.x, vf.minX - f.width + 80)        // at least 80pt visible at sides
        f.origin.x = min(f.origin.x, vf.maxX - 80)
        if f != window.frame { window.setFrame(f, display: true, animate: true) }
        frameChanged()
    }

    func frameChanged() {
        data.frame = window.frame
        board.scheduleSave()
    }

    func windowDidMove(_ n: Notification) { frameChanged() }
    func windowDidBecomeKey(_ n: Notification) { setChrome(true) }
    func windowDidResignKey(_ n: Notification) { setChrome(false) }

    func setChrome(_ visible: Bool) {
        if !visible, popover?.isShown == true { return }   // keep the bell visible while its picker is open
        chromeVisible = visible
        for v in chrome {
            if visible { v.isHidden = false }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                v.animator().alphaValue = visible ? 1 : 0
            }, completionHandler: { [weak self] in
                if self?.chromeVisible == false { v.isHidden = true }
            })
        }
    }
    func windowDidResize(_ n: Notification) { frameChanged() }

    func textDidChange(_ n: Notification) {
        data.text = textView.string
        textView.needsDisplay = true
        board.scheduleSave()
    }

    @objc func newSticker() { board.addSticker(near: window.frame) }

    // MARK: Ask Claude (chat window from the ✨ button)

    var chatPanel: ChatPanel?
    var askQueue: [String] = []      // questions waiting for an answer, oldest first
    var asking = false

    @objc func toggleChat() {
        if let c = chatPanel, c.isOpen { c.closeChat(); return }
        if chatPanel == nil { chatPanel = ChatPanel(sticker: self) }
        chatPanel?.show()
    }

    func ask(_ question: String) {
        data.chat = (data.chat ?? []) + [ChatLine(role: "user", text: question)]
        board.scheduleSave()
        askQueue.append(question)
        askNext()
        chatPanel?.render()
    }

    /// Questions on one sticker are answered one at a time, in order, so the conversation stays in sequence.
    func askNext() {
        guard !asking, let question = askQueue.first else { return }
        asking = true
        let note = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = (note.isEmpty ? "(The note is empty.)" : "The note currently says:\n\(note)") + "\n\nQuestion: \(question)"
        askClaude(prompt, session: data.agentSession) { [weak self] answer, session, error in
            guard let self = self else { return }
            if let a = answer {
                if let s = session { self.data.agentSession = s }
                self.data.chat = (self.data.chat ?? []) + [ChatLine(role: "claude", text: cleanAnswer(a))]
            } else {
                self.data.chat = (self.data.chat ?? []) + [ChatLine(role: "error", text: error ?? "No answer.")]
            }
            self.board.scheduleSave()
            self.askQueue.removeFirst()
            self.asking = false
            self.askNext()
            self.chatPanel?.render()
        }
    }

    // MARK: Reminders

    @objc func openReminder() {
        if popover?.isShown == true { popover?.close(); return }
        let start: Date = data.remindAt.map { Date(timeIntervalSince1970: $0) } ?? {
            // default: the next full hour
            let c = Calendar.current, next = Date().addingTimeInterval(3600)
            return c.date(bySettingHour: c.component(.hour, from: next), minute: 0, second: 0, of: next)!
        }()
        let picker = ReminderPicker(date: start, hasReminder: data.remindAt != nil)
        picker.onSet = { [weak self] d in self?.setReminder(d) }
        picker.onClear = { [weak self] in self?.setReminder(nil) }
        let p = NSPopover()
        p.contentViewController = picker
        p.behavior = .transient
        p.delegate = self
        popover = p
        p.show(relativeTo: bell.bounds, of: bell, preferredEdge: .maxY)
        board.askNotificationPermission()
    }

    func popoverDidClose(_ n: Notification) {
        if !window.isKeyWindow { setChrome(false) }
    }

    func setReminder(_ date: Date?) {
        popover?.close()
        data.remindAt = date?.timeIntervalSince1970
        updateReminderLabel()
        board.save()
    }

    func updateReminderLabel() {
        bell?.image = NSImage(systemSymbolName: data.remindAt == nil ? "bell" : "bell.fill",
                              accessibilityDescription: "Reminder")
        if ringing {
            reminderLabel.stringValue = "⏰ Reminder! Click to dismiss"
            reminderLabel.textColor = .systemOrange
        } else if let t = data.remindAt {
            reminderLabel.stringValue = "⏰ " + reminderFormatter.string(from: Date(timeIntervalSince1970: t))
            reminderLabel.textColor = inkColor.withAlphaComponent(0.65)
        } else {
            reminderLabel.stringValue = ""
        }
    }

    // Time's up: sound, notification, and the sticker jumps in front of everything and glows.
    func ring() {
        guard !ringing else { return }
        ringing = true
        data.remindAt = nil
        board.save()
        updateReminderLabel()

        window.level = .floating
        window.orderFrontRegardless()
        let orange = NSColor.systemOrange
        paper.layer?.borderWidth = 3
        paper.layer?.borderColor = orange.cgColor
        let pulse = CABasicAnimation(keyPath: "borderColor")
        pulse.fromValue = orange.cgColor
        pulse.toValue = orange.withAlphaComponent(0.15).cgColor
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        paper.layer?.add(pulse, forKey: "ring")
        // Ring for 30 seconds (or until you click the sticker).
        let started = Date()
        NSSound(named: "Glass")?.play()
        soundTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
            if Date().timeIntervalSince(started) >= 30 { t.invalidate(); return }
            NSSound(named: "Glass")?.play()
        }

        let firstLine = data.text.split(separator: "\n").first.map(String.init) ?? ""
        let content = UNMutableNotificationContent()
        content.title = "Sticker reminder"
        content.body = firstLine.isEmpty ? "You set a reminder on one of your stickers." : firstLine
        content.userInfo = ["sticker": data.id]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func stopRinging() {
        guard ringing else { return }
        ringing = false
        soundTimer?.invalidate()
        soundTimer = nil
        paper.layer?.removeAnimation(forKey: "ring")
        window.level = stickerLevel
        applyTheme()   // restores the normal border
        if board.hidden { window.orderOut(nil) }
    }

    @objc func deleteMe() {
        if !data.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Delete this sticker?"
            alert.informativeText = "What you wrote on it will be gone."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        board.remove(self)
    }
}

// MARK: - X feed panel (shows someone's x.com profile on the desktop)

struct FeedData: Codable {
    var id: String = UUID().uuidString
    var user: String
    var tweetsOnly: Bool? = nil          // nil = on (default)
    var x: Double, y: Double, w: Double, h: Double
    var frame: NSRect {
        get { NSRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }
}

// X shows "browser not supported" to unknown browsers, so present as regular Safari.
let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

// Keep any panel's top bar below the menu bar and part of it on screen.
func clampToScreen(_ window: NSWindow) {
    var f = window.frame
    let screen = NSScreen.screens.max { a, b in
        a.visibleFrame.intersection(f).width * a.visibleFrame.intersection(f).height <
        b.visibleFrame.intersection(f).width * b.visibleFrame.intersection(f).height
    } ?? NSScreen.main
    guard let vf = screen?.visibleFrame else { return }
    f.size.height = min(f.height, vf.height)
    f.size.width = min(f.width, vf.width)
    f.origin.y = min(f.origin.y, vf.maxY - f.height)
    f.origin.y = max(f.origin.y, vf.minY - f.height + 60)
    f.origin.x = max(f.origin.x, vf.minX - f.width + 80)
    f.origin.x = min(f.origin.x, vf.maxX - 80)
    if f != window.frame { window.setFrame(f, display: true, animate: true) }
}

// Runs inside the X page. When "tweets only" is on and we're on a profile, it hides every part of the
// page except the list of tweets: it walks up from the timeline and hides everything beside it.
let tweetsOnlyScript = """
(function () {
  if (window.__dnSet) return;
  const style = document.createElement('style');
  style.textContent = `
    html.dn-on .dn-hide { display: none !important; }
    html.dn-on article [role="group"] { display: none !important; }          /* reply / repost / like / views / bookmark / share */
    html.dn-on article [aria-label*="Grok" i] { display: none !important; }
    html.dn-on article button[aria-label="More"] { display: none !important; }   /* the "…" menu */
    html.dn-on article div:has(> [data-post-avatar]) { display: none !important; }   /* profile picture column */
    html.dn-on article img[src*="profile_images"] { display: none !important; }
    html.dn-on article div:has(> [data-testid="Tweet-User-Avatar"]),
    html.dn-on article [data-testid="Tweet-User-Avatar"],
    html.dn-on article [data-testid^="UserAvatar-Container"] { display: none !important; }
    html.dn-on article [data-testid="caret"] { display: none !important; }
    /* Stronger line between tweets (only recolours lines X already draws). */
    html.dn-on .dn-list > *, html.dn-on .dn-list > * > * {
      border-bottom-color: var(--dn-line) !important; border-top-color: var(--dn-line) !important;
    }
  `;
  document.documentElement.appendChild(style);
  let enabled = false, queued = false;
  const isProfile = () => /^\\/[A-Za-z0-9_]{1,15}\\/?$/.test(location.pathname);

  // The tweet list = the smallest element that contains every tweet (<article>) on the page.
  function tweetList() {
    // Only tweets actually shown on screen (X also keeps hidden copies in the page while loading).
    const tweets = [...document.querySelectorAll('article')]
      .filter(a => !a.parentElement.closest('article') && a.getClientRects().length > 0);
    if (!tweets.length) return null;
    let box = tweets[0].parentElement;
    while (box && !tweets.every(t => box.contains(t))) box = box.parentElement;
    return box;
  }
  function restore() {
    document.documentElement.classList.remove('dn-on');
    document.querySelectorAll('.dn-hide').forEach(e => e.classList.remove('dn-hide'));
  }
  function isolate() {
    const list = tweetList();
    if (!list) return;
    document.documentElement.classList.add('dn-on');
    list.classList.add('dn-list');
    // Divider colour: medium grey on X's light theme, lighter grey on its dark themes.
    const bg = getComputedStyle(document.body).backgroundColor.match(/\\d+/g) || [255, 255, 255];
    const darkPage = (0.2126 * bg[0] + 0.7152 * bg[1] + 0.0722 * bg[2]) < 128;
    document.documentElement.style.setProperty('--dn-line', darkPage ? 'rgb(95, 105, 115)' : 'rgb(190, 200, 207)');
    // Inside the list: hide anything that isn't a tweet ("Who to follow", banners, etc.).
    // Also hide the pinned post (X labels it "Pinned" above the tweet).
    const isPinned = el => [...el.querySelectorAll('[data-testid="socialContext"]')]
      .some(c => /^(Pinned|Angeheftet|Épinglé|Fijado|Fissato|Fixado|Vastgezet)/i.test(c.innerText.trim()));
    for (const child of list.children) {
      const hasTweet = child.tagName === 'ARTICLE' || child.querySelector('article');
      if (!hasTweet || isPinned(child)) child.classList.add('dn-hide');
      else child.classList.remove('dn-hide');
    }
    // In this person's own tweets: hide their name, badge and @handle, keep only the time.
    // (Reposts and quotes from other people keep their author's name.)
    const me = '/' + location.pathname.split('/')[1].toLowerCase();
    for (const head of list.querySelectorAll('[data-testid="User-Name"]')) {
      const time = head.querySelector('time');
      const own = [...head.querySelectorAll('a[href]')].some(a => a.getAttribute('href').toLowerCase() === me);
      if (!time || !own) continue;
      let el = time;
      while (el && el !== head && el.parentElement) {
        for (const sib of el.parentElement.children) if (sib !== el) sib.classList.add('dn-hide');
        el = el.parentElement;
      }
    }
    // In each tweet's top row: hide the icon-only buttons (the "…" menu and the Grok icon).
    for (const t of list.querySelectorAll('article')) {
      const top = t.getBoundingClientRect().top;
      for (const b of t.querySelectorAll('button, [role="button"]')) {
        if (b.classList.contains('dn-hide') || b.innerText.trim() !== '') continue;
        if (b.closest('[aria-label*="erified" i]') || b.getAttribute('aria-label')?.match(/verified/i)) continue;
        const r = b.getBoundingClientRect();
        if (r.width > 0 && r.top - top < 40) b.classList.add('dn-hide');
      }
    }
    // Outside the list: hide everything beside it, all the way up to the page itself.
    let el = list;
    while (el && el !== document.body && el.parentElement) {
      for (const sib of el.parentElement.children) {
        if (sib !== el && sib.tagName !== 'STYLE' && sib.tagName !== 'SCRIPT') sib.classList.add('dn-hide');
      }
      el = el.parentElement;
    }
  }
  function apply() {
    queued = false;
    if (enabled && isProfile()) isolate(); else restore();
  }
  new MutationObserver(() => { if (!queued) { queued = true; requestAnimationFrame(apply); } })
    .observe(document.documentElement, { childList: true, subtree: true });
  window.__dnSet = function (on) { enabled = !!on; apply(); };
})();
"""

final class FeedPanel: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    var data: FeedData
    let window: StickerWindow
    let paper = NSView()
    let glass = NSVisualEffectView()
    let barGlass = NSVisualEffectView()      // frosted background of the top bar (it floats over the tweets)
    let web: WKWebView
    let titleLabel = NSTextField(labelWithString: "")
    unowned let board: Board
    var chrome: [NSView] = []
    var chromeVisible = false
    var buttons: [NSButton] = []
    var refreshTimer: Timer?
    var loggedIn = false
    var filterButton: NSButton!
    var tweetsOnly: Bool { data.tweetsOnly ?? true }

    var profileURL: URL { URL(string: "https://x.com/\(data.user)")! }

    init(_ data: FeedData, board: Board) {
        self.data = data
        self.board = board
        window = StickerWindow(contentRect: data.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // keeps you logged in to X between restarts
        cfg.userContentController.addUserScript(
            WKUserScript(source: tweetsOnlyScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        build()
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                         target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func build() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = stickerLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.delegate = self

        paper.wantsLayer = true
        paper.layer?.cornerRadius = 8
        paper.layer?.masksToBounds = true
        window.contentView = paper
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.frame = paper.bounds
        glass.autoresizingMask = [.width, .height]
        paper.addSubview(glass)

        let bar = DragBar()
        bar.showsPill = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        barGlass.blendingMode = .withinWindow
        barGlass.state = .active
        barGlass.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(barGlass)
        NSLayoutConstraint.activate([
            barGlass.topAnchor.constraint(equalTo: bar.topAnchor),
            barGlass.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            barGlass.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            barGlass.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        ])

        let back = iconButton("chevron.left", "Back", #selector(goBack))
        let home = iconButton("arrow.clockwise", "Refresh / back to profile", #selector(goHome))
        let close = iconButton("xmark", "Remove this feed", #selector(removeMe))
        filterButton = iconButton("line.3.horizontal.decrease.circle", "Tweets only / full page", #selector(toggleTweetsOnly))
        buttons = [back, filterButton, home, close]
        buttons.forEach(bar.addSubview)

        titleLabel.stringValue = "@" + data.user
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(titleLabel)

        web.customUserAgent = safariUserAgent
        web.navigationDelegate = self
        web.uiDelegate = self
        web.pageZoom = 0.9
        web.translatesAutoresizingMaskIntoConstraints = false
        paper.addSubview(web)
        paper.addSubview(bar, positioned: .above, relativeTo: web)   // bar floats over the top of the page

        let grip = ResizeGrip()
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.onDone = { [weak self] in self?.keepOnScreen() }
        bar.onDrop = { [weak self] in self?.keepOnScreen() }
        paper.addSubview(grip)

        // Top bar buttons and resize corner only appear when you click the panel.
        chrome = [bar, grip]
        chrome.forEach { $0.isHidden = true; $0.alphaValue = 0 }

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: paper.topAnchor),
            bar.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 34),

            back.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            back.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            filterButton.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 10),
            filterButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            home.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -10),
            home.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            // Tweets fill the whole panel; no empty strip when the bar is hidden.
            web.topAnchor.constraint(equalTo: paper.topAnchor),
            web.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: paper.bottomAnchor),

            grip.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -3),
            grip.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -3),
            grip.widthAnchor.constraint(equalToConstant: 16),
            grip.heightAnchor.constraint(equalToConstant: 16),
        ])

        applyTheme()
        updateFilterIcon()
        web.configuration.websiteDataStore.httpCookieStore.add(self)
        web.load(URLRequest(url: profileURL))
        window.orderFrontRegardless()
        keepOnScreen()

        // Refresh every hour while you're not using the panel.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.autoRefresh()
        }
        refreshTimer?.tolerance = 60
    }

    func applyTheme() {
        let light = board.lightStyle
        glass.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        glass.material = light ? .popover : .hudWindow
        glass.alphaValue = light ? 0.75 : 0.7
        barGlass.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        barGlass.material = light ? .popover : .hudWindow
        paper.layer?.borderWidth = 1
        paper.layer?.borderColor = (light ? NSColor.black.withAlphaComponent(0.10)
                                          : NSColor.white.withAlphaComponent(0.08)).cgColor
        titleLabel.textColor = inkColor.withAlphaComponent(0.8)
        buttons.forEach { $0.contentTintColor = inkColor.withAlphaComponent(0.55) }
    }

    // MARK: Tweets-only mode

    @objc func toggleTweetsOnly() {
        data.tweetsOnly = !tweetsOnly
        updateFilterIcon()
        applyMode()
        board.scheduleSave()
    }

    func updateFilterIcon() {
        filterButton.image = NSImage(systemSymbolName: tweetsOnly ? "line.3.horizontal.decrease.circle.fill"
                                                                  : "line.3.horizontal.decrease.circle",
                                     accessibilityDescription: "Tweets only")
        filterButton.toolTip = tweetsOnly ? "Showing tweets only — click for the full page"
                                          : "Showing the full page — click for tweets only"
    }

    // Turn the filter off (full page) to log in or browse.
    func applyMode() {
        let on = tweetsOnly
        web.evaluateJavaScript("window.__dnSet && window.__dnSet(\(on))", completionHandler: nil)
    }

    func checkLogin() {
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let was = self.loggedIn
            self.loggedIn = cookies.contains { $0.name == "auth_token" && ($0.domain.hasSuffix("x.com") || $0.domain.hasSuffix("twitter.com")) }
            // Just logged in and X sent you to its home feed: go back to this person's profile.
            if self.loggedIn && !was, self.web.url?.path == "/home" { self.goHome() }
            self.applyMode()
        }
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        DispatchQueue.main.async { self.checkLogin() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if loggedIn, webView.url?.path == "/home" { goHome(); return }
        checkLogin()
    }


    func autoRefresh() {
        guard !board.hidden, !window.isKeyWindow, !web.isLoading else { return }
        let onProfile = web.url?.path.lowercased() == "/" + data.user.lowercased()
        if onProfile { web.reload() } else { web.load(URLRequest(url: profileURL)) }
    }

    func keepOnScreen() {
        clampToScreen(window)
        data.frame = window.frame
        board.scheduleSave()
    }

    func windowDidMove(_ n: Notification) { data.frame = window.frame; board.scheduleSave() }
    func windowDidResize(_ n: Notification) { data.frame = window.frame; board.scheduleSave() }
    func windowDidBecomeKey(_ n: Notification) { setChrome(true) }
    func windowDidResignKey(_ n: Notification) { setChrome(false) }

    func setChrome(_ visible: Bool) {
        chromeVisible = visible
        for v in chrome {
            if visible { v.isHidden = false }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                v.animator().alphaValue = visible ? 1 : 0
            }, completionHandler: { [weak self] in
                if self?.chromeVisible == false { v.isHidden = true }
            })
        }
    }

    @objc func goBack() { if web.canGoBack { web.goBack() } else { goHome() } }
    @objc func goHome() { web.load(URLRequest(url: profileURL)) }

    @objc func removeMe() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove the @\(data.user) feed?"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        refreshTimer?.invalidate()
        web.configuration.websiteDataStore.httpCookieStore.remove(self)
        board.removeFeed(self)
    }

    // Links that want a new window: X / login pages stay in the panel, everything else opens in your browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        let host = url.host?.lowercased() ?? ""
        let stayInside = ["x.com", "twitter.com", "google.com", "apple.com"].contains { host == $0 || host.hasSuffix("." + $0) }
        if stayInside { webView.load(action.request) } else { NSWorkspace.shared.open(url) }
        return nil
    }
}

// MARK: - All stickers + saving

final class Board {
    var stickers: [Sticker] = []
    var feeds: [FeedPanel] = []

    // Sticker style: "auto" follows the wallpaper, or forced "light" / "dark".
    var styleMode: String = UserDefaults.standard.string(forKey: "stickerStyle") ?? "auto" {
        didSet { UserDefaults.standard.set(styleMode, forKey: "stickerStyle"); refreshTheme() }
    }
    private var wallpaperLight = wallpaperIsLight()
    private var lastWallpaper = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    var lightStyle: Bool { styleMode == "auto" ? wallpaperLight : styleMode == "light" }

    func refreshTheme() {
        wallpaperLight = wallpaperIsLight()
        lastWallpaper = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        inkColor = lightStyle ? darkInk : .white
        stickers.forEach { $0.applyTheme() }
        feeds.forEach { $0.applyTheme() }
    }

    // Notice when the wallpaper is changed in System Settings (checked every 3 seconds, very cheap).
    func watchWallpaper() {
        inkColor = lightStyle ? darkInk : .white
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            if now != self.lastWallpaper { self.refreshTheme() }
        }
    }
    var onHiddenChange: (() -> Void)?
    // Remembered across restarts.
    var hidden: Bool = UserDefaults.standard.bool(forKey: "stickersHidden") {
        didSet {
            UserDefaults.standard.set(hidden, forKey: "stickersHidden")
            applyHidden()
            onHiddenChange?()
        }
    }

    func applyHidden() {
        for st in stickers {
            if hidden { st.chatPanel?.closeChat(); st.window.orderOut(nil) } else { st.window.orderFrontRegardless() }
        }
        for f in feeds {
            if hidden { f.window.orderOut(nil) } else { f.window.orderFrontRegardless() }
        }
    }

    // MARK: X feeds

    func loadFeeds() {
        guard let raw = try? Data(contentsOf: feedsURL),
              let list = try? JSONDecoder().decode([FeedData].self, from: raw) else { return }
        list.forEach { feeds.append(FeedPanel($0, board: self)) }
    }

    func addFeed(user: String) {
        if hidden { hidden = false }
        let s = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let h = min(720, s.height - 80)
        let offset = CGFloat(feeds.count) * 30
        var d = FeedData(user: user, x: 0, y: 0, w: 0, h: 0)
        d.frame = NSRect(x: s.minX + 60 + offset, y: s.maxY - h - 40 - offset, width: 420, height: h)
        let f = FeedPanel(d, board: self)
        feeds.append(f)
        save()
    }

    func removeFeed(_ f: FeedPanel) {
        f.window.orderOut(nil)
        f.window.delegate = nil
        feeds.removeAll { $0 === f }
        save()
    }
    private var saveTimer: Timer?

    func load() {
        if let raw = try? Data(contentsOf: storeURL),
           let list = try? JSONDecoder().decode([StickerData].self, from: raw) {
            list.forEach { stickers.append(Sticker(onScreen($0), board: self)) }
        } else {
            // First run: turn the old single note into the first sticker.
            let oldText = (try? String(contentsOf: oldNotesURL, encoding: .utf8)) ?? ""
            var d = StickerData(x: 0, y: 0, w: 440, h: 380)
            d.text = oldText
            d.frame = defaultFrame()
            stickers.append(Sticker(d, board: self))
            save()
        }
    }

    func defaultFrame() -> NSRect {
        let s = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: s.maxX - 480, y: s.maxY - 420, width: 440, height: 380)
    }

    // If a sticker was on a screen that's no longer connected, bring it back.
    func onScreen(_ d: StickerData) -> StickerData {
        var d = d
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(d.frame) }) {
            d.frame = defaultFrame()
        }
        return d
    }

    func addSticker(near: NSRect?) {
        if hidden { hidden = false }
        var f = near.map { $0.offsetBy(dx: -($0.width + 20), dy: 0) } ?? defaultFrame()
        f.size = NSSize(width: 360, height: 300)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        if f.minX < screen.minX { f.origin.x = near.map { $0.minX + 30 } ?? screen.midX; f.origin.y -= 40 }
        var d = StickerData(x: 0, y: 0, w: 0, h: 0)
        d.frame = f
        d.color = stickers.count % palette.count
        let s = Sticker(d, board: self)
        stickers.append(s)
        NSApp.activate(ignoringOtherApps: true)
        s.window.makeKeyAndOrderFront(nil)
        s.window.makeFirstResponder(s.textView)
        save()
    }

    func remove(_ s: Sticker) {
        s.chatPanel?.closeChat()
        s.window.orderOut(nil)
        s.window.delegate = nil
        stickers.removeAll { $0 === s }
        save()
    }

    func bringAllBack() {
        let s = NSScreen.main?.visibleFrame ?? .zero
        for (i, st) in stickers.enumerated() {
            let f = NSRect(x: s.minX + 40 + CGFloat(i % 4) * 380, y: s.maxY - 320 - CGFloat(i / 4) * 320,
                           width: st.window.frame.width, height: st.window.frame.height)
            st.window.setFrame(f, display: true, animate: true)
        }
        save()
    }

    // MARK: Reminders

    private var askedPermission = false
    func askNotificationPermission() {
        guard !askedPermission else { return }
        askedPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Checks every 5 seconds, and right after the Mac wakes from sleep.
    func startReminderClock() {
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkReminders() }
        t.tolerance = 1
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkReminders()
        }
        checkReminders()   // reminders that came due while the app was off ring right away
    }

    func checkReminders() {
        let now = Date().timeIntervalSince1970
        for s in stickers where (s.data.remindAt ?? .infinity) <= now { s.ring() }
    }

    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in self?.save() }
    }

    func save() {
        saveTimer?.invalidate()
        saveTimer = nil
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let raw = try? enc.encode(stickers.map { $0.data }) else { return }
        try? FileManager.default.createDirectory(at: lifeDir, withIntermediateDirectories: true)
        try? raw.write(to: storeURL, options: .atomic)
        if let feedRaw = try? enc.encode(feeds.map { $0.data }) {
            try? feedRaw.write(to: feedsURL, options: .atomic)
        }
    }
}

// MARK: - App + menu bar icon

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let board = Board()
    var statusItem: NSStatusItem!
    var toggleItem: NSMenuItem!
    var styleItems: [NSMenuItem] = []
    var fontItems: [NSMenuItem] = []

    @objc func pickFont(_ sender: NSMenuItem) {
        stickerFontName = sender.representedObject as? String ?? "Noteworthy-Light"
        UserDefaults.standard.set(stickerFontName, forKey: "stickerFont")
        stickerFont = makeFont(stickerFontName)
        board.stickers.forEach { $0.applyTheme() }
        refreshFontChecks()
    }

    func refreshFontChecks() {
        for it in fontItems { it.state = (it.representedObject as? String) == stickerFontName ? .on : .off }
    }

    @objc func pickStyle(_ sender: NSMenuItem) {
        board.styleMode = sender.representedObject as? String ?? "auto"
        refreshStyleChecks()
    }

    func refreshStyleChecks() {
        for it in styleItems { it.state = (it.representedObject as? String) == board.styleMode ? .on : .off }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMainMenu()
        buildStatusItem()
        board.watchWallpaper()
        board.load()
        board.loadFeeds()
        board.applyHidden()
        UNUserNotificationCenter.current().delegate = self
        board.startReminderClock()
    }

    func applicationWillTerminate(_ n: Notification) { board.save() }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Stickers")
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector) { menu.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self }
        add("New sticker", #selector(newSticker))
        add("Add X feed…", #selector(addFeed))
        toggleItem = menu.addItem(withTitle: "", action: #selector(toggleHidden), keyEquivalent: "")
        toggleItem.target = self
        board.onHiddenChange = { [weak self] in self?.refreshToggle() }
        refreshToggle()
        add("Change wallpaper…", #selector(changeWallpaper))
        let styleItem = menu.addItem(withTitle: "Sticker style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for (title, mode) in [("Automatic (match wallpaper)", "auto"), ("Light", "light"), ("Dark", "dark")] {
            let it = styleMenu.addItem(withTitle: title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode
            styleItems.append(it)
        }
        styleItem.submenu = styleMenu
        refreshStyleChecks()
        let fontItem = menu.addItem(withTitle: "Font", action: nil, keyEquivalent: "")
        let fontMenu = NSMenu()
        for (title, name, _) in fontChoices {
            let it = fontMenu.addItem(withTitle: title, action: #selector(pickFont(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = name
            // Show each option written in its own font.
            it.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: name == "system" ? NSFont.menuFont(ofSize: 14) : (NSFont(name: name, size: 15) ?? NSFont.menuFont(ofSize: 14))])
            fontItems.append(it)
        }
        fontItem.submenu = fontMenu
        refreshFontChecks()
        menu.addItem(.separator())
        add("Line up all stickers", #selector(lineUp))
        add("Show saved file in Finder", #selector(reveal))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Stickers", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
    }

    @objc func newSticker() { board.addSticker(near: nil) }

    @objc func addFeed() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add an X feed"
        alert.informativeText = "Type the X username (like @nasa) or paste a link to their profile."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "@username"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var user = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: user), let host = url.host?.lowercased(),
           host.hasSuffix("x.com") || host.hasSuffix("twitter.com") {
            user = url.pathComponents.dropFirst().first ?? ""
        }
        user = user.replacingOccurrences(of: "@", with: "")
        guard user.range(of: "^[A-Za-z0-9_]{1,15}$", options: .regularExpression) != nil else {
            let bad = NSAlert()
            bad.messageText = "That doesn't look like an X username"
            bad.informativeText = "Usernames are up to 15 letters, numbers or underscores, like @nasa."
            bad.runModal()
            return
        }
        board.addFeed(user: user)
    }

    // Show notifications even though this app is running.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }

    // Clicking the notification brings that sticker forward.
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let id = r.notification.request.content.userInfo["sticker"] as? String
        DispatchQueue.main.async {
            if let s = self.board.stickers.first(where: { $0.data.id == id }) {
                NSApp.activate(ignoringOtherApps: true)
                s.window.orderFrontRegardless()
                s.window.makeKey()
            }
        }
        done()
    }
    @objc func toggleHidden() { board.hidden.toggle() }

    func refreshToggle() {
        toggleItem.title = board.hidden ? "Show all stickers" : "Hide all stickers"
        // Menu bar icon shows a crossed-out eye while stickers are hidden.
        statusItem.button?.image = NSImage(systemSymbolName: board.hidden ? "eye.slash" : "note.text",
                                           accessibilityDescription: "Stickers")
    }
    @objc func lineUp() { if board.hidden { board.hidden = false }; board.bringAllBack() }
    @objc func reveal() { board.save(); NSWorkspace.shared.activateFileViewerSelecting([storeURL]) }

    @objc func changeWallpaper() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose a wallpaper"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let picked = panel.url else { return }

        // Keep a copy so the wallpaper survives if the original file is moved or deleted.
        try? FileManager.default.createDirectory(at: wallpaperDir, withIntermediateDirectories: true)
        let copy = wallpaperDir.appendingPathComponent(picked.lastPathComponent)
        if copy.path != picked.path {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.copyItem(at: picked, to: copy)
        }
        let url = FileManager.default.fileExists(atPath: copy.path) ? copy : picked

        var failed = false
        for screen in NSScreen.screens {
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]) } catch { failed = true }
        }
        board.refreshTheme()
        if failed {
            let a = NSAlert()
            a.messageText = "Couldn't set that wallpaper"
            a.informativeText = "Try another image, or set it in System Settings → Wallpaper."
            a.runModal()
        }
    }

    func buildMainMenu() {
        // Invisible (no Dock icon) but makes ⌘C ⌘V ⌘Z ⌘A work while typing.
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
