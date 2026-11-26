// DesktopNote — sticky notes that live on your wallpaper.
// Everything is saved automatically to ~/Desktop/life/stickers.json

import Cocoa
import UniformTypeIdentifiers
import UserNotifications

let lifeDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/life")
let storeURL = lifeDir.appendingPathComponent("stickers.json")
let oldNotesURL = lifeDir.appendingPathComponent("notes.txt")
let wallpaperDir = lifeDir.appendingPathComponent("wallpapers")

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
    var frame: NSRect {
        get { NSRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }
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
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event); onDrop?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
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
        let title = NSTextField(labelWithString: "Remind me on")
        title.font = .boldSystemFont(ofSize: 13)

        cal.datePickerStyle = .clockAndCalendar
        cal.datePickerElements = .yearMonthDay
        cal.dateValue = initial
        cal.minDate = Calendar.current.startOfDay(for: Date())

        time.datePickerStyle = .textFieldAndStepper
        time.datePickerElements = .hourMinute
        time.dateValue = initial
        let timeRow = NSStackView(views: [NSTextField(labelWithString: "at"), time])

        msg.textColor = .systemRed
        msg.font = .systemFont(ofSize: 11)
        msg.isHidden = true

        let set = NSButton(title: "Set reminder", target: self, action: #selector(setTapped))
        set.keyEquivalent = "\r"
        var bottom: [NSView] = []
        if hasReminder { bottom.append(NSButton(title: "Remove", target: self, action: #selector(clearTapped))) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottom += [spacer, set]
        let bottomRow = NSStackView(views: bottom)

        let stack = NSStackView(views: [title, cal, timeRow, msg, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
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
        buttons = [add, bell, delete]
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

            reminderLabel.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 14),
            reminderLabel.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -3),
            reminderLabel.trailingAnchor.constraint(lessThanOrEqualTo: grip.leadingAnchor, constant: -4),
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

// MARK: - All stickers + saving

final class Board {
    var stickers: [Sticker] = []

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
            if hidden { st.window.orderOut(nil) } else { st.window.orderFrontRegardless() }
        }
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
