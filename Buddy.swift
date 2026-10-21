// Rick-Rubin-inspired 8-bit desktop buddy.
//
// A borderless, transparent, always-on-top window that sits on the desktop,
// reacts to what Claude Code is doing, and occasionally says something. Lives in
// the menu bar; no Dock icon.
//
// Drag him anywhere; click him for a nod and a line; right-click him or use the
// menu bar icon for settings.
//
// Build:  swiftc -O Buddy.swift -o buddy
// Run:    ./buddy [framesDir] [scale]

import AppKit
import CoreAudio
import Darwin

// A separate suite lets integration checks run without touching a user's Rick.
let appDirectory = Bundle.main.bundleURL.pathExtension == "app"
    ? (Bundle.main.resourceURL ?? Bundle.main.bundleURL) : Bundle.main.bundleURL

let preferences: UserDefaults = ProcessInfo.processInfo.environment["RUBIN_PREFS_SUITE"]
    .flatMap { UserDefaults(suiteName: $0) } ?? .standard

struct AgentSession: Codable {
    let id: String
    let project: String
    let phase: String
    let detail: String
    let updated: Double
    let event: String
    let provider: String?
    var agentName: String { provider == "codex" ? "Codex" : "Claude" }

    func effectivePhase(at now: Double) -> String {
        // Silence is not evidence of completion. Keep an unresolved wait until
        // that session resumes/ends; label stale work as unknown rather than done.
        if phase == "working", now - updated > 1800 { return "unknown" }
        return phase
    }

    static func ordered(_ sessions: [AgentSession], at now: Double,
                        acknowledged: [String: Double]) -> [AgentSession] {
        let priority = ["waiting": 5, "ready": 4, "working": 3, "unknown": 2, "idle": 1]
        return sessions.filter {
            $0.phase != "ended" && now - $0.updated < 7 * 86400
                && ($0.phase != "ready" || (acknowledged[$0.id] ?? 0) < $0.updated)
        }.sorted {
            let a = priority[$0.effectivePhase(at: now)] ?? 0
            let b = priority[$1.effectivePhase(at: now)] ?? 0
            return a == b ? $0.updated > $1.updated : a > b
        }
    }
}

final class CompanionPanel: NSViewController {
    let statusLabel = NSTextField(wrappingLabelWithString: "Keeping you company")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let thoughtLabel = NSTextField(wrappingLabelWithString: "")
    let focusButton = NSButton(title: "Sit with me · 25 minutes", target: nil, action: nil)
    let breathButton = NSButton(title: "Take a breath · 1 minute", target: nil, action: nil)
    let keepButton = NSButton(title: "Keep this thought", target: nil, action: nil)
    let quietButton = NSButton(title: "A little quiet · 1 hour", target: nil, action: nil)
    let reviewButton = NSButton(title: "Clear reviewed completions", target: nil, action: nil)
    let noticeLabel = NSTextField(wrappingLabelWithString: "")
    var onAction: ((String) -> Void)?
    var icon: NSImage?

    override func loadView() {
        let surface = NSVisualEffectView()
        surface.material = .popover
        surface.state = .active
        view = surface
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            surface.widthAnchor.constraint(equalToConstant: 346),
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -20),
        ])
        let title = NSTextField(labelWithString: "Rick")
        title.font = NSFont(name: "Georgia", size: 26) ?? .systemFont(ofSize: 26)
        let subtitle = NSTextField(labelWithString: "A little company for the work.")
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        let sprite = NSImageView()
        sprite.image = icon
        sprite.imageScaling = .scaleProportionallyUpOrDown
        sprite.widthAnchor.constraint(equalToConstant: 39).isActive = true
        sprite.heightAnchor.constraint(equalToConstant: 51).isActive = true
        let top = NSStackView(views: [sprite, heading])
        top.spacing = 14
        stack.addArrangedSubview(top)
        func add(_ child: NSView) {
            stack.addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        func line() { let rule = NSBox(); rule.boxType = .separator; add(rule) }
        line()
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        add(statusLabel); add(detailLabel)
        thoughtLabel.font = NSFont(name: "Georgia", size: 19) ?? .systemFont(ofSize: 19)
        add(thoughtLabel)
        func action(_ button: NSButton, _ name: String) {
            button.identifier = NSUserInterfaceItemIdentifier(name)
            let symbols = ["keep":"bookmark", "picture":"photo.on.rectangle", "focus":"sun.max", "breath":"wind", "quiet":"moon", "review":"checkmark"]
            if let symbol = symbols[name] { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = .imageLeading }
            button.target = self; button.action = #selector(clicked(_:))
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.alignment = .left
            add(button)
        }
        action(keepButton, "keep")
        action(NSButton(title: "Copy picture to share", target: nil, action: nil), "picture")
        line()
        action(focusButton, "focus")
        action(breathButton, "breath")
        action(quietButton, "quiet")
        action(reviewButton, "review")
        let footer = NSStackView()
        footer.distribution = .fillEqually
        for (label, name) in [("Saved thoughts", "saved"), ("Settings", "settings")] {
            let button = NSButton(title: label, target: self, action: #selector(clicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(name)
            button.bezelStyle = .rounded
            footer.addArrangedSubview(button)
        }
        add(footer)
        noticeLabel.font = .systemFont(ofSize: 12)
        noticeLabel.textColor = .secondaryLabelColor
        add(noticeLabel)
    }

    @objc private func clicked(_ sender: NSButton) {
        if let name = sender.identifier?.rawValue { onAction?(name) }
    }
}

let PAPER = NSColor(srgbRed: 0.965, green: 0.953, blue: 0.925, alpha: 1)  // beard white
let INK = NSColor(srgbRed: 0.090, green: 0.071, blue: 0.059, alpha: 1)  // outline

// MARK: - Single instance

/// Held for the process lifetime; the flock releases when we exit, however we go.
var instanceLockDescriptor: Int32 = -1

/// Two of him on screen is confusing, and both copies would fight over the same
/// state file and saved position. Cheaper to refuse than to coordinate: an
/// advisory flock that the kernel drops for us on exit, so a crash can't leave a
/// stale lock behind the way a pidfile would.
func acquireInstanceLock(at directory: URL) -> Bool {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(".lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }  // can't lock: better to run than not to
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        return false
    }
    instanceLockDescriptor = fd
    return true
}

// MARK: - Geometry

/// One sprite pixel, in points, such that it covers a whole number of *device*
/// pixels. At fractional scales an unsnapped size makes some sprite pixels 4
/// device pixels wide and others 5, which reads as a wobble on straight edges.
func snappedPixelSize(scale: Double, screen: NSScreen?) -> Double {
    let backing = Double(screen?.backingScaleFactor ?? 2.0)
    let devicePixels = max(1.0, (scale * backing).rounded())
    return devicePixels / backing
}

// MARK: - Updates

/// Checks the repo's VERSION file and reinstalls when it's newer.
///
/// Pinned to one repo and one file over HTTPS. The heavy lifting is in
/// install.sh, which builds from source and only replaces the running copy once
/// the build succeeds — so a broken commit upstream can't leave you with a
/// buddy that won't start.
enum Updater {
    static let repo = "Gitmealez/rubin-buddy"
    static let branch = "main"

    /// The contents API, not raw.githubusercontent.com. Raw serves a cached copy
    /// for about five minutes — irrelevant for the periodic check, but it makes a
    /// manual "Check for Updates" report the old version right after a release.
    /// The API is uncached; 60 requests/hour unauthenticated is far more than a
    /// six-hourly poll needs.
    static var versionURL: URL {
        URL(string: "https://api.github.com/repos/\(repo)/contents/VERSION?ref=\(branch)")!
    }
    /// Falls back here if the API is unreachable or rate-limited.
    static var versionFallbackURL: URL {
        URL(string: "https://raw.githubusercontent.com/\(repo)/\(branch)/VERSION")!
    }
    static var installerURL: URL {
        URL(string: "https://rick-buddy.netlify.app/install.sh")!
    }

    /// Numeric compare, so 1.10.0 correctly beats 1.9.0 — a plain string
    /// comparison gets that backwards.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        }
        let (r, l) = (parts(remote), parts(local))
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func fetch(_ url: URL, api: Bool, _ done: @escaping (String?) -> Void) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        if api {
            // Hands back the file's bytes instead of JSON with base64 in it.
            request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        }
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200,
                let text = data.flatMap({ String(data: $0, encoding: .utf8) })?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty, text.first?.isNumber == true
            else {
                done(nil)
                return
            }
            done(text)
        }.resume()
    }

    static func fetchLatest(_ done: @escaping (String?) -> Void) {
        fetch(versionURL, api: true) { viaAPI in
            if let viaAPI {
                DispatchQueue.main.async { done(viaAPI) }
                return
            }
            fetch(versionFallbackURL, api: false) { viaRaw in
                DispatchQueue.main.async { done(viaRaw) }
            }
        }
    }

    /// Runs the installer detached. It stops the old copy and starts the new
    /// one itself, so this process is expected to die partway through — which
    /// is why it must not be a child that dies with us.
    /// Runs the installer detached. Success normally kills this very process
    /// (the installer replaces and restarts us), so the termination handler
    /// firing with a bad status — or at all, in a process still alive — means
    /// the update failed and someone should hear about it.
    ///
    /// Downloaded to a file first, never `curl | sh`: piping executes the
    /// script as it streams, and a dropped connection mid-transfer would run a
    /// truncated prefix of it. RUBIN_AUTO=1 tells the installer it's running
    /// headless so it must never prompt.
    static var installerTask: Process?

    static func runInstaller(onFailure: @escaping (String) -> Void) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubin-buddy-install-\(getpid()).sh")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "curl -fsSL '\(installerURL.absoluteString)' -o '\(tmp.path)' "
                + "&& RUBIN_AUTO=1 sh '\(tmp.path)'; s=$?; rm -f '\(tmp.path)'; exit $s",
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        task.terminationHandler = { finished in
            installerTask = nil
            if finished.terminationStatus != 0 {
                DispatchQueue.main.async {
                    onFailure("Update failed. Run ~/.rubin-buddy/update.sh in Terminal.")
                }
            }
        }
        do {
            try task.run()
            installerTask = task
        } catch {
            onFailure("Couldn't start the update.")
        }
    }
}

// MARK: - Login item

/// The launchd agent that starts him at login. Toggled from the menu bar.
enum LoginItem {
    static let label = "co.desklify.rubinbuddy"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static func launchctl(_ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    static func setEnabled(_ on: Bool, executable: String, logPath: String) {
        let domain = "gui/\(getuid())"
        guard on else {
            // Deliberately no `bootout`: disabling "start at login" shouldn't
            // also kill the copy that's running right now. Removing the plist
            // is enough to stop it loading next login.
            try? FileManager.default.removeItem(at: plistURL)
            launchctl(["disable", "\(domain)/\(label)"])
            return
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            // Restart him after a crash; menu Quit exits 0 and stays quit.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardErrorPath": logPath,
        ]
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        {
            try? data.write(to: plistURL)
        }
        launchctl(["enable", "\(domain)/\(label)"])
        // Fails harmlessly if the job is already bootstrapped this session.
        launchctl(["bootstrap", domain, plistURL.path])
    }
}

// MARK: - Frame loading

struct Frame {
    let image: NSImage
    let hold: Int
}

struct Animation {
    let frames: [Frame]
    /// Animation to settle into once this one finishes a cycle; nil loops.
    let next: String?
    /// Where the shades sit when this animation ends: "up" or "down".
    let shades: String
    /// Where they sat when it started. Only differs for transitions.
    let from: String
    let isTransition: Bool
    /// A step the app plays on its way somewhere else (a hop, the headphones
    /// going on). Kept out of the Pose menu.
    let isInternal: Bool
}

struct SpriteSet {
    let pixelWidth: Int
    let pixelHeight: Int
    /// Image rows below the ground line his feet stand on.
    let baseline: Int
    let animations: [String: Animation]
    let menuIcon: NSImage?

    init(framesDir: URL) throws {
        func fail(_ message: String) -> NSError {
            NSError(domain: "buddy", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let data = try Data(contentsOf: framesDir.appendingPathComponent("manifest.json"))
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let width = root["width"] as? Int,
            let height = root["height"] as? Int,
            let anims = root["animations"] as? [String: [String: Any]]
        else { throw fail("malformed manifest.json") }

        var loaded: [String: Animation] = [:]
        for (name, spec) in anims {
            guard let frames = spec["frames"] as? [[String: Any]] else {
                throw fail("\(name): no frames")
            }
            let parsed = try frames.map { entry -> Frame in
                guard
                    let file = entry["file"] as? String,
                    let hold = entry["hold"] as? Int,
                    let image = NSImage(contentsOf: framesDir.appendingPathComponent(file))
                else { throw fail("\(name): bad frame") }
                return Frame(image: image, hold: hold)
            }
            let shades = spec["shades"] as? String ?? "down"
            loaded[name] = Animation(
                frames: parsed,
                next: spec["next"] as? String,
                shades: shades,
                from: spec["from"] as? String ?? shades,
                isTransition: spec["transition"] as? Bool ?? false,
                isInternal: spec["internal"] as? Bool ?? false)
        }

        self.pixelWidth = width
        self.pixelHeight = height
        self.baseline = root["baseline"] as? Int ?? 2
        self.animations = loaded

        if let icon = NSImage(contentsOf: framesDir.appendingPathComponent("menubar.png")) {
            icon.size = NSSize(width: 16, height: 16)
            icon.isTemplate = true  // macOS recolours it per menu bar appearance
            self.menuIcon = icon
        } else {
            self.menuIcon = nil
        }
    }

    /// The gesture that moves the shades between two positions, if there is one.
    func transition(from: String, to: String) -> String? {
        animations.first { $0.value.isTransition && $0.value.from == from && $0.value.shades == to }?
            .key
    }
}

// MARK: - Sprite view

final class SpriteView: NSView {
    var image: NSImage?
    var onClick: (() -> Void)?
    var onGrab: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    private var grabOffset: NSPoint = .zero
    private var didDrag = false

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        // Nearest-neighbour, or the pixel art turns to mush when scaled up.
        image.draw(
            in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0,
            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
    }

    override func mouseDown(with event: NSEvent) {
        grabOffset = event.locationInWindow
        didDrag = false
        onGrab?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        didDrag = true
        let cursor = NSEvent.mouseLocation
        let proposed = NSPoint(x: cursor.x - grabOffset.x, y: cursor.y - grabOffset.y)
        // Refuse a move that would put him entirely off every display. Crossing
        // between monitors still works; vanishing doesn't.
        let frame = NSRect(origin: proposed, size: window.frame.size)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return }
        window.setFrameOrigin(proposed)
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag { onDragEnd?() } else { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}

// MARK: - Speech bubble

final class BubbleView: NSView {
    var text = ""
    var pixel: Double = 3
    var tailX: Double = 20
    var tailDown = true
    var font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .medium)
    /// The wrap width the window was sized against. Laying the text out at any
    /// other width here can pull a word onto the previous line, and then the
    /// height the window was built for no longer matches what's drawn.
    var wrapWidth: Double = 190

    static let tailDepth: Double = 3  // in sprite pixels

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        let p = min(pixel, 2)
        let tail = p * Self.tailDepth
        let cut = p * 3  // soft bevel, while preserving the pixel character

        let body = NSRect(
            x: 0, y: tailDown ? tail : 0, width: bounds.width, height: bounds.height - tail)

        // One path for bubble + tail, so the border comes out uniform on both.
        let path = NSBezierPath()
        let tipY = tailDown ? 0 : bounds.height
        let baseY = tailDown ? body.minY : body.maxY
        let tx = min(max(tailX, body.minX + cut + p * 2), body.maxX - cut - p * 2)

        path.move(to: NSPoint(x: body.minX + cut, y: baseY))
        path.line(to: NSPoint(x: tx - p * 2, y: baseY))
        path.line(to: NSPoint(x: tx, y: tipY))
        path.line(to: NSPoint(x: tx + p * 2, y: baseY))
        path.line(to: NSPoint(x: body.maxX - cut, y: baseY))
        let farY = tailDown ? body.maxY : body.minY
        let step = tailDown ? -cut : cut
        path.line(to: NSPoint(x: body.maxX, y: baseY - step))
        path.line(to: NSPoint(x: body.maxX, y: farY + step))
        path.line(to: NSPoint(x: body.maxX - cut, y: farY))
        path.line(to: NSPoint(x: body.minX + cut, y: farY))
        path.line(to: NSPoint(x: body.minX, y: farY + step))
        path.line(to: NSPoint(x: body.minX, y: baseY - step))
        path.close()

        // Hard edges on the bevels and the tail — this is meant to look drawn
        // on a grid, not vector-smooth.
        ctx.saveGraphicsState()
        ctx.shouldAntialias = true
        PAPER.setFill()
        path.fill()
        // Stroking at 2x width against the path's own clip leaves a border
        // exactly `pixel` thick, all the way around the tail included.
        path.addClip()
        INK.setStroke()
        path.lineWidth = 1.5
        path.stroke()
        ctx.restoreGraphicsState()

        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: INK]
        let size = (text as NSString).boundingRect(
            with: NSSize(width: wrapWidth, height: body.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs
        ).size
        (text as NSString).draw(
            in: NSRect(
                x: body.minX + (body.width - size.width) / 2,
                y: body.minY + (body.height - size.height) / 2,
                width: size.width, height: size.height),
            withAttributes: attrs)
    }
}

final class Bubble {
    private let window: NSWindow
    private let view = BubbleView()
    private var hideWork: DispatchWorkItem?

    private static let maxTextWidth: Double = 260

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.ignoresMouseEvents = true  // never in the way of a click
        window.contentView = view
    }

    var isVisible: Bool { window.isVisible }

    private var size = NSSize.zero
    private var pixel: Double = 2

    func show(
        _ text: String, over buddy: NSRect, pixel: Double, screen: NSScreen?,
        duration: Double? = nil
    ) {
        let pixel = min(pixel, 2)
        self.pixel = pixel
        let savedSize = preferences.double(forKey: "buddyTextSize")
        let fontSize = savedSize > 0 ? max(13, min(22, savedSize)) : 15
        let font = NSFont(name: "Georgia", size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .medium)

        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).boundingRect(
            with: NSSize(width: Self.maxTextWidth, height: 400),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs
        ).size

        let padX = pixel * 3
        let padY = pixel * 2
        let tail = pixel * BubbleView.tailDepth
        size = NSSize(
            width: (textSize.width + padX * 2 + pixel * 2).rounded(.up),
            height: (textSize.height + padY * 2 + pixel * 2).rounded(.up) + tail)

        view.text = text
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(text)
        view.pixel = pixel
        view.font = font
        view.wrapWidth = Self.maxTextWidth
        view.needsDisplay = true
        place(over: buddy, screen: screen)
        window.orderFrontRegardless()

        hideWork?.cancel()
        // Dense scripts read slower than their character count suggests: one
        // CJK ideograph is a whole word, and anyone studying the line is
        // reading it three times over (hanzi, romanization, meaning). Those
        // lines linger 14-20s; everything else keeps the quick 3-9s.
        let dense = text.unicodeScalars.contains {
            (0x3400...0x9FFF).contains($0.value)      // CJK ideographs
                || (0x3040...0x30FF).contains($0.value)  // kana
                || (0xAC00...0xD7AF).contains($0.value)  // hangul
        }
        // Spelled out step by step: as one ?? / ?: expression this took Swift
        // 6.4's type-checker past its time limit, and every install builds it.
        let characters = Double(text.count)
        let reading: Double = dense
            ? min(20.0, max(14.0, 3.0 + characters * 0.2))
            : min(9.0, max(3.0, 2.0 + characters * 0.07))
        let seconds = duration ?? reading
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// He moves now — riding a window, hopping to another — and the bubble
    /// goes with him rather than being left talking to an empty spot.
    func follow(_ buddy: NSRect, screen: NSScreen?) {
        guard window.isVisible else { return }
        place(over: buddy, screen: screen)
    }

    private func place(over buddy: NSRect, screen: NSScreen?) {
        let (w, h) = (size.width, size.height)
        let area = (screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap = pixel

        // Prefer above him; flip below if there isn't room.
        var tailDown = true
        var y = buddy.maxY + gap
        if y + h > area.maxY {
            tailDown = false
            y = buddy.minY - h - gap
        }
        var x = buddy.midX - w / 2
        x = min(max(x, area.minX + 4), area.maxX - w - 4)

        if view.tailDown != tailDown || view.tailX != buddy.midX - x {
            view.tailDown = tailDown
            view.tailX = buddy.midX - x
            view.needsDisplay = true
        }
        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        window.orderOut(nil)
    }
}

// MARK: - Music

/// Whether music is playing — Spotify, Apple Music, a YouTube tab, anything.
///
/// Two sources. Spotify and Apple Music announce play and pause to the whole
/// system, instantly; for them that's the truth. Everything else comes from
/// Core Audio's list of processes using the sound output, which needs no
/// permission and carries nothing of the sound itself — only which apps are
/// making some. That's checked once a second, and it takes a few seconds of
/// steady output to count (a notification ding isn't music) and a few of quiet
/// to stop. A call isn't music either: an app using the microphone too is
/// talking, and the usual meeting apps are left out entirely.
///
/// Nothing about WHAT is playing is read or kept.
final class MusicWatcher: NSObject {
    var onChange: ((Bool) -> Void)?
    private(set) var isPlaying = false

    /// Players that announce themselves, by family, and their last word.
    private var announced: [String: Bool] = [:]
    /// Debounced Core Audio verdict for everyone else.
    private var heard = false
    private var disagreements = 0
    private var lastLook = Date.distantPast
    /// Each audio process's app. A process object keeps its id for life, so
    /// this is asked once per process rather than every second.
    private var families: [AudioObjectID: String] = [:]

    private static let players = [
        "com.spotify.client.PlaybackStateChanged": "com.spotify.client",
        "com.apple.Music.playerInfo": "com.apple.Music",
    ]
    /// Apple's own processes make sound for all sorts of reasons (screen
    /// mirroring, dictation, alerts); only these are listening material.
    private static let appleListening: Set<String> = [
        "com.apple.Music", "com.apple.podcasts", "com.apple.TV", "com.apple.Safari",
        "com.apple.WebKit", "com.apple.QuickTimePlayerX", "com.apple.iTunes",
    ]
    /// Calls and meetings: never music, even with the microphone muted.
    private static let talking: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "Cisco-Systems.Spark",
        "com.cisco.webexmeetingsapp", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "net.whatsapp.WhatsApp", "com.skype.skype", "co.around.Around", "app.tuple.app",
    ]

    override init() {
        super.init()
        let center = DistributedNotificationCenter.default()
        for name in Self.players.keys {
            // deliverImmediately: AppKit suspends distributed notifications for
            // an app that isn't active, and a menu bar buddy never is.
            center.addObserver(
                self, selector: #selector(playerChanged(_:)), name: Notification.Name(name),
                object: nil, suspensionBehavior: .deliverImmediately)
        }
        // A player that quits mid-song says nothing on the way out.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appQuit(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func playerChanged(_ note: Notification) {
        guard let player = Self.players[note.name.rawValue] else { return }
        announced[player] = note.userInfo?["Player State"] as? String == "Playing"
        update()
    }

    @objc private func appQuit(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if let id = app?.bundleIdentifier, announced[id] != nil {
            announced[id] = false
            update()
        }
    }

    /// Once a second. Three seconds of sound to start, four of quiet to stop.
    /// A full look costs a few milliseconds of round trips to Core Audio, so:
    /// none at all while nothing is using the speakers, and once the answer
    /// has held steady, every other second is plenty.
    func poll() {
        let now: Bool
        if !Self.speakersInUse() {
            now = false
        } else if disagreements == 0, Date().timeIntervalSince(lastLook) < 1.9 {
            now = heard
        } else {
            lastLook = Date()
            now = !audibleFamilies().subtracting(announced.keys).isEmpty
        }
        disagreements = now == heard ? 0 : disagreements + 1
        if disagreements >= (now ? 3 : 4) {
            heard = now
            disagreements = 0
            update()
        }
    }

    private func update() {
        let playing = heard || announced.values.contains(true)
        guard playing != isPlaying else { return }
        isPlaying = playing
        onChange?(playing)
    }

    /// `com.google.Chrome.helper` plays for `com.google.Chrome`.
    private static func family(_ bundle: String) -> String {
        bundle.split(separator: ".").prefix(3).joined(separator: ".")
    }

    private static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    /// Is anything at all playing through the default output? One cheap
    /// question that rules out the full look most of the day.
    static func speakersInUse() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return true }  // can't tell: take the full look
        return flag(device, kAudioDevicePropertyDeviceIsRunningSomewhere)
    }

    /// Apps with sound going out right now and no microphone in use.
    private func audibleFamilies() -> Set<String> {
        guard #available(macOS 14.2, *) else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &bytes) == noErr, bytes > 0
        else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &bytes, &processes) == noErr
        else { return [] }
        families = families.filter { processes.contains($0.key) }

        func bundle(_ process: AudioObjectID) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
                let id = value?.takeRetainedValue() as String?, !id.isEmpty
            else { return nil }
            return id
        }

        func app(_ process: AudioObjectID) -> String? {
            if let known = families[process] { return known.isEmpty ? nil : known }
            let found = bundle(process).map(Self.family) ?? ""  // unnamed helpers: can't tell
            families[process] = found
            return found.isEmpty ? nil : found
        }

        let playing = Set(processes.filter { Self.flag($0, kAudioProcessPropertyIsRunningOutput) }
            .compactMap(app))
            .filter { !Self.talking.contains($0)
                && (!$0.hasPrefix("com.apple.") || Self.appleListening.contains($0)) }
        guard !playing.isEmpty else { return [] }
        // Only the playing apps' processes need asking about the microphone.
        let calling = Set(processes.filter { app($0).map(playing.contains) == true
            && Self.flag($0, kAudioProcessPropertyIsRunningInput) }.compactMap(app))
        return playing.subtracting(calling)
    }
}

// MARK: - Windows to stand on

/// The window he stands on: the frontmost app's frontmost ordinary window, in
/// AppKit coordinates. Read from the window list, which gives bounds and owners
/// without any permission — titles would need Screen Recording, and he never
/// asks for them.
enum PerchTarget {
    /// One of his own windows is in front (the companion panel, a menu): stay put.
    case keep
    /// Nothing to stand on — the desktop, or an app with no windows open.
    case none
    case window(id: CGWindowID, frame: NSRect, app: String)

    static func current() -> PerchTarget {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .none }
        let pid = app.processIdentifier
        if pid == getpid() { return .keep }
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return .none }
        // The window list's origin is the top-left of the menu bar display.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == pid,
                (info[kCGWindowLayer as String] as? Int) == 0,
                (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                let number = info[kCGWindowNumber as String] as? Int,
                let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds),
                rect.width >= 200, rect.height >= 120  // not a palette or a popover
            else { continue }
            return .window(
                id: CGWindowID(number),
                frame: NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height),
                app: app.bundleIdentifier ?? "pid \(pid)")
        }
        return .none
    }
}

// MARK: - Controller

final class Buddy: NSObject, NSMenuDelegate {
    private let sprites: SpriteSet
    private let window: NSWindow
    private let view: SpriteView
    private let stateFile: URL
    private let linesFile: URL

    private let bubble = Bubble()
    private var statusItem: NSStatusItem?
    private var companionWindow: NSPanel?
    private var companionPanel: CompanionPanel?
    private var savedWindow: NSPanel?
    private var sessions: [AgentSession] = []
    private var lastSessionEvent = ""
    private var sessionCache: [String: (Date, AgentSession)] = [:]
    private var acknowledged = preferences.dictionary(forKey: "buddyReviewed") as? [String: Double] ?? [:]
    private var focusUntil: Date? = {
        let time = preferences.double(forKey: "buddyFocusUntil")
        return time > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: time) : nil
    }()
    private var isFocusing: Bool { focusUntil.map { $0 > Date() } ?? false }
    private var showStatusLabel: Bool {
        preferences.object(forKey: "buddyShowStatus") as? Bool ?? true
    }
    private var keptThoughts: [String] {
        get { preferences.stringArray(forKey: "buddyKeptThoughts") ?? [] }
        set { preferences.set(newValue, forKey: "buddyKeptThoughts") }
    }
    private var pixel: Double = 4
    private var requestedScale: Double
    /// Guards against re-entering the resize from the notification it posts.
    private var adjustingScale = false

    private var currentAnimation = "idle"
    private var frameIndex = 0
    private var ticksOnFrame = 0
    /// Animation to run once the transition gesture currently playing finishes.
    private var pendingTarget: String?
    private var timer: Timer?

    private var lastStateStamp: Date?
    private var ticksSinceStatePoll = 0
    private var ticksUntilSpeaking = 0
    /// Shuffled deck, so every line plays before any repeats. Persisted, and
    /// that matters more than it looks: auto-updates restart him, and an
    /// in-memory deck meant every release re-dealt from the top — with weekly
    /// releases, nobody ever got deep enough into the deck to avoid repeats.
    private var lineBag: [String] = []
    private var bagSourceHash = ""
    private var deckRestored = false
    private static let deckKey = "buddyDeck"
    private static let deckSourceKey = "buddyDeckSource"

    /// The last ~50 lines he actually said, newest last. Contextual draws are
    /// filtered against this — the theme pools are small (a dozen lines), and
    /// drawing WITH replacement from them made same-day repeats near-certain.
    private var recentLines: [String] =
        preferences.stringArray(forKey: "buddyRecentLines") ?? []
    private static let recentKey = "buddyRecentLines"
    private static let recentCap = 50

    // Contextual speech: the moment picks the theme, the theme picks the line.
    private var lastContextual = Date.distantPast
    /// Start of the current unbroken stretch of Claude Code activity.
    private var activeSince = Date()
    private var lastStateEvent = Date()
    /// Set while he's in the shades-up "your turn" state.
    private var waitingSince: Date?
    private var saidWaitingLine = false

    // Idle fidgets. Only ever started FROM idle, so returning to idle when one
    // ends is always right; a real state event cancels the return outright.
    private var fidgetUntil: Date?
    private var nextFidgetAt = Date.distantFuture
    private var lastFidget = ""

    // Music. Headphones go on when anything plays music, and he grooves
    // through the work — only Claude needing you takes them off.
    private let music = MusicWatcher()
    private static let grooveKey = "buddyGroove"
    private var grooveEnabled: Bool { preferences.object(forKey: Self.grooveKey) as? Bool ?? true }
    private var grooveWanted: Bool { grooveEnabled && music.isPlaying && !isFocusing && !isBreathing }
    /// The headphones-on states. Leaving them always goes through "unphones".
    private static let musicStates: Set<String> = [
        "phones", "groove", "charge-phones", "flip-phones", "land-phones",
    ]
    /// When the music last stopped. Its return after a long silence earns a word.
    private var musicStoppedAt = Date.distantPast

    // Perching. He stands on the front window and hops when it changes.
    private static let perchKey = "buddyPerch"
    private static let perchSpotKey = "buddyPerchSpot"
    private var perchEnabled: Bool { preferences.bool(forKey: Self.perchKey) }
    /// How far along the window's edge he stands: 0 left, 1 right. Set by
    /// dragging him along it.
    private var perchSpot = preferences.object(forKey: "buddyPerchSpot") as? Double ?? 0.85
    /// The window he's on; 0 is his home spot; nil means look again and hop.
    private var perchedOn: CGWindowID?
    private var perchFrame: NSRect?
    private var perchApp: String?
    /// Where you've put him inside each app's windows, as fractions of the
    /// window (x from the left, y from the bottom). Wins over the top edge.
    private static let appSpotsKey = "buddyAppSpots"
    private var appSpots = preferences.dictionary(forKey: "buddyAppSpots") as? [String: [Double]] ?? [:]
    /// The band at a window's top kept clear inside it: title bar and toolbar.
    private static let toolbarBand = 92.0
    /// A different window came to the front, and when. Hops wait a beat for it
    /// to settle, so flicking through Cmd-Tab doesn't send him bouncing.
    private var perchCandidate: (id: CGWindowID, since: Date)?
    private var ticksSincePerchPoll = 0
    /// Poll every tick until then: the window he's on is being dragged.
    private var perchFastUntil = Date.distantPast
    private var isDragging = false

    private struct Hop {
        let from: NSPoint
        let to: NSPoint
        /// Liftoff. Before it he's still in the crouch.
        let start: Date
        let duration: TimeInterval
        let height: Double
        /// A real jump. Otherwise he glides the same arc in whatever he's
        /// doing: headphones on, seated, shades up.
        let leaps: Bool
        /// The full jump: charge, spin, land. Short hops skip the ceremony.
        let charged: Bool
        /// Whole turns of the tuck in the air, and which way he's travelling.
        let spins: Int
        let rightward: Bool
        /// Headphones on: the jump in its headphones-on frames.
        let phones: Bool
        /// What to go back to after landing.
        let resume: String?
        var launched = false
    }
    /// One-shot effects left behind (the launch burst), held until they finish.
    private var effects: [NSWindow] = []
    private var hop: Hop?
    /// A pose asked for mid-jump. It plays once he lands.
    private var afterHop: String?
    /// Poses he jumps from. Anything holding a prop or sitting glides instead.
    private static let leapingPoses: Set<String> = [
        "idle", "think", "stroke", "nod", "glance", "adjust", "glint", "land", "touchdown",
        "groove", "land-phones",
    ]
    /// Shorter than this, a jump is a hop: no charge, no spin.
    private static let chargedJumpFrom = 120.0

    /// Seconds you've spent actively at the machine since your last real break.
    private var activeSeconds: TimeInterval = 0
    private var ticksSincePresencePoll = 0

    /// The seated states. Entering meditate goes through sitdown; leaving any of
    /// them goes through standup — request() enforces both.
    private static let sittingStates: Set<String> = ["sitdown", "meditate"]

    /// Pending steps of a guided breath; empty means not breathing.
    private var breathWork: [DispatchWorkItem] = []
    private var isBreathing: Bool { !breathWork.isEmpty }

    /// Why he's seated, when he is — each reason has its own "stand up" rule.
    /// "away": you left; your return ends it. "night": it's late; morning (or
    /// an event) ends it. "long": Claude's been at one task a while; the Stop
    /// ends it. nil: you asked for the sit, so it's yours to end.
    private var sitReason: String?

    /// When the current unbroken run of think/stroke began; nil when not busy.
    private var busySince: Date?

    /// The last thing he said, surfaced in the menu for anyone who caught the
    /// bubble vanishing and wondered.
    private var lastSaid = preferences.string(forKey: "buddyLastThought") ?? ""

    /// Quiet for an Hour: every unprompted mouth stays shut until this passes.
    /// Persisted, because an auto-update restarting him mid-meeting must not
    /// un-mute him. Explicit asks (clicks, Say Something, the breath) still work.
    private var quietUntil =
        Date(timeIntervalSince1970: preferences.double(forKey: "buddyQuietUntil"))
    private static let quietKey = "buddyQuietUntil"
    private var inQuietHour: Bool { Date() < quietUntil }

    private let localVersion: String
    /// True when running from the installed location, where update.sh applies.
    /// A developer checkout updates with git, not by being overwritten.
    private let isManagedInstall: Bool
    private var updateTimer: Timer?

    private static let originKey = "buddyOrigin"
    private static let scaleKey = "buddyScale"
    private static let chatterKey = "buddyChatter"
    private static let autoUpdateKey = "buddyAutoUpdate"
    private static let updateCheckInterval: TimeInterval = 6 * 60 * 60
    private static let tickInterval = 1.0 / 30.0
    private static let ticksPerSecond = 30
    private static let statePollTicks = 6  // ~200ms

    /// Seconds of quiet between unprompted lines; nil means he stays silent.
    static var quietSecondsRange: ClosedRange<Int>? = 150...420
    /// RUBIN_DEBUG=1 logs every animation change to stderr.
    static var debug = false
    /// True when RUBIN_SCALE / a scale argument was given at launch — an
    /// explicit ask that outranks the remembered menu choice for this run.
    static var scaleFromLaunch = false
    /// Likewise for RUBIN_CHATTER.
    static var chatterFromLaunch = false

    // Contextual-speech timing. Vars, not lets, so RUBIN_CTX_FAST can shrink
    // them for testing — the triggers are otherwise hours apart by design.
    /// Minimum gap between contextual lines, shared across all three triggers.
    static var ctxCooldown: TimeInterval = 15 * 60
    /// How long Claude must be waiting on you before he says something.
    static var ctxWait: TimeInterval = 3 * 60
    /// Unbroken activity before he suggests stepping away.
    static var ctxStretch: TimeInterval = 2 * 60 * 60
    /// A pause longer than this ends the stretch.
    static var ctxGap: TimeInterval = 15 * 60
    /// Quiet time between idle fidgets, and how long one runs. Between turns he
    /// used to be a two-frame bob for minutes on end — most of what anyone ever
    /// saw of him. Now idleness has a life of its own.
    static var fidgetEvery: ClosedRange<Double> = 20...55
    static var fidgetLength: ClosedRange<Double> = 3.5...7
    /// The re-arm used when he COMES TO REST (nod/idle event). The general
    /// re-arm on every event meant active sessions starved fidgets completely —
    /// events landed faster than the 25-75s timer could ever expire. Coming to
    /// rest is different from being interrupted: a gesture should arrive soon.
    static var fidgetAfterRest: ClosedRange<Double> = 8...25
    /// Break nudge: after this long actively at the machine — keyboard or mouse
    /// input within the last minute, YOUR presence, not Claude's activity — he
    /// suggests going to live a little.
    static var breakEvery: TimeInterval = 90 * 60
    /// Being away from the machine this long counts as a break taken.
    static var breakReset: TimeInterval = 15 * 60
    /// When you've been away this long, he sits down and meditates.
    static var meditateAfter: TimeInterval = 8 * 60
    /// A busy pose (think/stroke) with no state event for this long means the
    /// session died without a Stop; he drifts back to idle.
    static var busyStaleAfter: TimeInterval = 30 * 60
    /// Claude working one task longer than this: he sits down and keeps watch —
    /// patience reads better than ten more minutes of beard-stroking.
    static var longTaskAfter: TimeInterval = 10 * 60
    /// Local hours (start, end) between which idle becomes the seated pose.
    static var nightWindow = (start: 23, end: 5)

    private static let sizeChoices: [(String, Double)] = [
        ("Tiny", 2.0), ("Small", 2.5), ("Medium", 3.5), ("Large", 5.0),
    ]
    private static let chatterChoices: [(String, ClosedRange<Int>?)] = [
        ("Silent", nil), ("Quiet", 300...900), ("Normal", 150...420), ("Talkative", 45...120),
    ]

    private static let fallbackLines = ["Let it breathe.", "Slower.", "Less."]

    init(sprites: SpriteSet, scale: Double, stateFile: URL, linesFile: URL) {
        self.sprites = sprites
        self.stateFile = stateFile
        self.linesFile = linesFile
        // Precedence: an explicit env/argument beats the remembered menu choice
        // (you typed it, you meant it); the menu choice beats the default.
        let stored = preferences.double(forKey: Self.scaleKey)
        self.requestedScale = Buddy.scaleFromLaunch ? scale : (stored > 0 ? stored : scale)

        let here = appDirectory
        self.localVersion =
            (try? String(contentsOf: here.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"
        let installDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".rubin-buddy")
        self.isManagedInstall =
            here.standardizedFileURL.path == installDir.standardizedFileURL.path

        view = SpriteView(frame: .zero)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: .borderless, backing: .buffered, defer: false)

        super.init()

        // Standing on windows is new. A fresh install starts with it; anyone who
        // already put him somewhere keeps that spot until they choose it.
        let returning = preferences.bool(forKey: "buddyHasRun")
        if preferences.object(forKey: Self.perchKey) == nil {
            preferences.set(!returning, forKey: Self.perchKey)
        }

        if !Buddy.chatterFromLaunch,
            let stored = preferences.string(forKey: Self.chatterKey),
            let match = Self.chatterChoices.first(where: { $0.0 == stored })
        {
            Self.quietSecondsRange = match.1
        }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.contentView = view

        // Pick the scale from the display his saved position sits on, before the
        // window exists. Using NSScreen.main here would bring him up at the
        // laptop's scale even when he's parked on a monitor with a different one,
        // and nothing would correct it until some screen notification fired.
        pixel = snappedPixelSize(
            scale: requestedScale,
            screen: Self.screen(containing: Self.storedOriginPoint()) ?? NSScreen.main)
        let size = spriteSize()
        window.setFrame(NSRect(origin: savedOrigin(size: size), size: size), display: false)

        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("Rick. Click for a thought; right-click for settings.")
        view.onGrab = { [weak self] in
            guard let self else { return }
            self.bubble.hide()
            self.isDragging = true
            self.cancelHop()
        }
        view.onClick = { [weak self] in
            guard let self else { return }
            self.isDragging = false
            // Mid-breath, a click means "enough" — he stands, nothing more.
            if self.isBreathing {
                self.cancelBreath(standUp: true)
                return
            }
            if self.isFocusing { self.speakLine(); return }
            // Waiting on you, eyes on you: a nod would drop the shades and lose
            // the waiting posture. He's already giving you his attention. And
            // with the headphones on, a nod is what he's already doing.
            if self.currentAnimation == "look" || Self.musicStates.contains(self.currentAnimation) {
                self.speakLine()
                return
            }
            self.request("nod")
            self.speakLine()
        }
        view.onDragEnd = { [weak self] in
            guard let self else { return }
            self.isDragging = false
            self.dropped()
        }
        music.onChange = { [weak self] playing in self?.musicChanged(playing) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.ticksSincePerchPoll = 999 }  // look now, not in half a second
        view.onRightClick = { [weak self] event in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.buildMenu(), with: event, for: self.view)
        }

        try? FileManager.default.createDirectory(
            at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Whatever state the previous session left on disk is history, not news —
        // without this he'd replay a stale "stroke" from last week at every launch.
        lastStateStamp =
            (try? FileManager.default.attributesOfItem(atPath: stateFile.path))?[
                .modificationDate] as? Date

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensRearranged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        installStatusItem()
        scheduleNextLine()
        scheduleNextFidget()

        if !preferences.bool(forKey: "buddyWelcome2") {
            preferences.set(true, forKey: "buddyWelcome2")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, !self.inQuietHour, Buddy.quietSecondsRange != nil else { return }
                self.say("A little company. Click my menu bar head for a breath, a thought, or a quiet sit.")
            }
        }

        // Someone who's had him a while learns about the new tricks once, from
        // him, a little after launch — not from a changelog they'll never read.
        if !preferences.bool(forKey: "buddyNews3") {
            preferences.set(true, forKey: "buddyNews3")
            if returning {
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self, !self.isBreathing, !self.bubble.isVisible, !self.inQuietHour,
                        Buddy.quietSecondsRange != nil else { return }
                    self.say(self.perchEnabled
                        ? "New: headphones on when your music plays."
                        : "New: headphones when your music plays, and I can stand on your windows. It’s in Settings.")
                }
            }
        }

        // First run ever: say something soon, so a new user learns he talks
        // without waiting the usual several minutes for the first line.
        let firstRunKey = "buddyHasRun"
        if !preferences.bool(forKey: firstRunKey) {
            preferences.set(true, forKey: firstRunKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, !self.isBreathing, !self.bubble.isVisible, !self.inQuietHour else { return }
                self.speakLine()
            }
        }

        renderCurrentFrame()
        window.orderFrontRegardless()

        // .common, not .default: a timer in the default mode stops while any
        // menu is open, which froze him mid-frame whenever you used the menu bar.
        let tickTimer = Timer(timeInterval: Self.tickInterval, repeats: true) {
            [weak self] _ in self?.tick()
        }
        RunLoop.main.add(tickTimer, forMode: .common)
        timer = tickTimer
        if isFocusing { request("meditate") }

        log("bundle=\(appDirectory.path) managed=\(isManagedInstall) v=\(localVersion)")
        if isManagedInstall {
            // Not at the instant of launch — logging in is busy enough already.
            let delay =
                Double(ProcessInfo.processInfo.environment["RUBIN_UPDATE_DELAY"] ?? "") ?? 45
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.checkForUpdates(userAsked: false)
            }
            updateTimer = Timer.scheduledTimer(
                withTimeInterval: Self.updateCheckInterval, repeats: true
            ) { [weak self] _ in self?.checkForUpdates(userAsked: false) }
        }
    }

    private func spriteSize() -> NSSize {
        NSSize(
            width: Double(sprites.pixelWidth) * pixel,
            height: Double(sprites.pixelHeight) * pixel)
    }

    // MARK: scale and displays

    /// Anchor the scale decision to the display under his origin, not to
    /// `window.screen`. `window.screen` is whichever display he *most overlaps*,
    /// and resizing changes the overlap — which on a mixed-DPI setup makes the
    /// choice flip back and forth forever.
    private static func screen(containing point: NSPoint?) -> NSScreen? {
        guard let point else { return nil }
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func anchorScreen() -> NSScreen? {
        Self.screen(containing: window.frame.origin) ?? window.screen ?? NSScreen.main
    }

    @objc private func screenChanged() {
        // setFrame below posts didChangeScreenNotification, which lands here
        // again. Without this guard that recursion is unbounded and the stack
        // gives out — a real crash when dragged between mixed-DPI displays.
        guard !adjustingScale else { return }
        let snapped = snappedPixelSize(scale: requestedScale, screen: anchorScreen())
        guard snapped != pixel else { return }

        adjustingScale = true
        defer { adjustingScale = false }
        pixel = snapped
        // Keep his feet where they are while the box around him changes.
        let old = window.frame
        let size = spriteSize()
        window.setFrame(
            NSRect(x: old.minX, y: old.minY, width: size.width, height: size.height), display: true)
    }

    /// A display being unplugged can leave him stranded off-screen. This rescue
    /// is temporary, so it deliberately does NOT overwrite the saved position —
    /// plug the display back in, relaunch, and he's where you left him.
    @objc private func screensRearranged() {
        screenChanged()
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
            return
        }
        bringBack(persist: false)
    }

    private func applyScale(_ scale: Double) {
        requestedScale = scale
        preferences.set(scale, forKey: Self.scaleKey)
        let snapped = snappedPixelSize(scale: scale, screen: anchorScreen())
        adjustingScale = true
        defer { adjustingScale = false }
        pixel = snapped
        let old = window.frame
        let size = spriteSize()
        window.setFrame(
            NSRect(x: old.minX, y: old.minY, width: size.width, height: size.height), display: true)
        bubble.hide()
    }

    // MARK: position

    /// Bottom-right of the main screen, clear of the Dock.
    private func defaultOrigin(size: NSSize) -> NSPoint {
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: area.maxX - size.width - 24, y: area.minY + 24)
    }

    private static func storedOriginPoint() -> NSPoint? {
        guard
            let saved = preferences.dictionary(forKey: originKey) as? [String: Double],
            let x = saved["x"], let y = saved["y"]
        else { return nil }
        return NSPoint(x: x, y: y)
    }

    private func savedOrigin(size: NSSize) -> NSPoint {
        if let point = Self.storedOriginPoint(),
            // Only reuse it if that spot is still on a connected display.
            NSScreen.screens.contains(where: {
                $0.visibleFrame.intersects(NSRect(origin: point, size: size))
            })
        { return point }
        return defaultOrigin(size: size)
    }

    private func saveOrigin() {
        let origin = window.frame.origin
        preferences.set(
            ["x": Double(origin.x), "y": Double(origin.y)], forKey: Self.originKey)
    }

    // MARK: animation

    private var animation: Animation? {
        sprites.animations[currentAnimation] ?? sprites.animations["idle"]
    }

    /// Ask for an animation. Inserts a shades-up/shades-down gesture first when
    /// the target's shade position doesn't match where they currently are, and
    /// routes into and out of sitting through sitdown/standup.
    private func request(_ name: String) {
        guard let target = sprites.animations[name] else { return }
        // Mid-jump the body is busy. Whatever was asked for plays on landing.
        if hop?.leaps == true {
            afterHop = name
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            var resting = name
            var visited = Set<String>()
            while let next = sprites.animations[resting]?.next, !visited.contains(next) {
                visited.insert(resting); resting = next
            }
            pendingTarget = nil
            play(resting)
            return
        }

        // The headphones come off before he does anything else, the same way
        // standup comes before anything that isn't sitting.
        if Self.musicStates.contains(currentAnimation), !Self.musicStates.contains(name),
            name != "unphones"
        {
            pendingTarget = name == "idle" ? nil : name  // unphones resolves to idle itself
            play("unphones")
            return
        }
        if currentAnimation == "phones", name == "groove" { return }  // already on the way

        // Leaving the floor: anything that isn't sitting goes through standup.
        if Self.sittingStates.contains(currentAnimation), !Self.sittingStates.contains(name),
            name != "standup"
        {
            sitReason = nil
            pendingTarget = name == "idle" ? nil : name  // standup resolves to idle itself
            play("standup")
            return
        }
        let here = sprites.animations[currentAnimation]?.shades ?? "down"

        // Taking the floor: meditate always begins by sitting down — and if the
        // shades are up, they come down first rather than teleporting.
        if name == "meditate", !Self.sittingStates.contains(currentAnimation) {
            if here == "up", let bridge = sprites.transition(from: "up", to: "down") {
                pendingTarget = "meditate"
                play(bridge)
            } else {
                pendingTarget = nil  // a stale target must not hijack the sit
                play("sitdown")
            }
            return
        }

        if target.isTransition {
            // Asked to move the shades somewhere they already are — skip the
            // gesture and go straight to where it would have landed.
            if target.shades == here {
                if let next = target.next { play(next) }
                return
            }
        } else if target.shades != here,
            let bridge = sprites.transition(from: here, to: target.shades)
        {
            pendingTarget = name
            play(bridge)
            return
        }

        // Standing, shades down: now the headphones can go on — unless they
        // already are (landing a jump with them on).
        if name == "groove", !Self.musicStates.contains(currentAnimation) {
            pendingTarget = nil
            play("phones")
            return
        }

        pendingTarget = nil
        play(name)
    }

    /// Music changes the meaning of "nothing much is happening": with it
    /// playing, rest is the groove, and so is Claude working or finishing —
    /// that's in the menu bar. Claude needing you still takes the headphones off.
    private func withMusic(_ pose: String) -> String {
        grooveWanted && ["idle", "think", "stroke", "nod"].contains(pose) ? "groove" : pose
    }

    private func play(_ name: String) {
        guard sprites.animations[name] != nil else { return }
        if Buddy.debug {
            FileHandle.standardError.write("play \(currentAnimation) -> \(name)\n".data(using: .utf8)!)
        }
        currentAnimation = name
        frameIndex = 0
        ticksOnFrame = 0
        renderCurrentFrame()
    }

    private func tick() {
        ticksSinceStatePoll += 1
        if ticksSinceStatePoll >= Self.statePollTicks {
            ticksSinceStatePoll = 0
            pollState()
        }

        if Buddy.quietSecondsRange != nil {
            ticksUntilSpeaking -= 1
            if ticksUntilSpeaking <= 0 {
                if !bubble.isVisible && window.isVisible && !isBreathing && !inQuietHour && !isFocusing && companionWindow?.isVisible != true { speakLine() }
                scheduleNextLine()
            }
        }

        // Claude has been waiting on you a while: shades up, and after ctxWait
        // he says so — you're the decision now. Once per wait.
        if let since = waitingSince, !saidWaitingLine {
            let now = Date()
            if now.timeIntervalSince(since) >= Self.ctxWait, canSpeakContextual(now) {
                saidWaitingLine = true
                speakContextual(["noticing", "taste over technique"], at: now)
            }
        }

        ticksSincePresencePoll += 1
        if ticksSincePresencePoll >= Self.ticksPerSecond {
            ticksSincePresencePoll = 0
            pollSessions()
            pollFocus()
            refreshPanel()
            pollPresence()
            music.poll()
        }

        // Idle fidgets. A gesture ends by returning to idle; a state event that
        // arrives mid-fidget takes over immediately (pollState clears the timer).
        if let until = fidgetUntil {
            if Date() >= until {
                fidgetUntil = nil
                // Only reel him back in if he's still doing the fidget. If a
                // breath, a Pose pick, or anything else took over meanwhile,
                // this timer has no business standing him back up.
                if ["stroke", "think", "glasses", "look", "glance", "adjust", "stretch", "tea", "glint"]
                    .contains(currentAnimation)
                {
                    request("idle")
                }
                scheduleNextFidget()
            }
        } else if currentAnimation == "idle", Date() >= nextFidgetAt, !isFocusing,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Never the same gesture twice running — uniform draws clump, and
            // clumping is what reads as "he only ever does one thing."
            let pool = ["stroke", "think", "glasses", "glance", "adjust", "stretch", "tea", "glint"]
                .filter { $0 != lastFidget }
            if let gesture = pool.randomElement() {
                lastFidget = gesture
                fidgetUntil = Date().addingTimeInterval(.random(in: Self.fidgetLength))
                request(gesture)
            }
        }

        // Standing on windows: a look at the window list (about a millisecond)
        // twice a second, at once when you switch apps, five times a second
        // while a new window settles, and every tick while one is moving.
        ticksSincePerchPoll += 1
        let following = Date() < perchFastUntil || NSEvent.pressedMouseButtons & 1 != 0
        if perchEnabled, ticksSincePerchPoll >= (following ? 1 : perchCandidate != nil ? 6 : 15) {
            ticksSincePerchPoll = 0
            updatePerch()
        }
        stepHop()

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let animation, !animation.frames.isEmpty else { return }
        ticksOnFrame += 1
        guard ticksOnFrame >= max(1, animation.frames[frameIndex].hold) else { return }

        ticksOnFrame = 0
        frameIndex += 1
        if frameIndex >= animation.frames.count {
            frameIndex = 0
            if let pending = pendingTarget {
                pendingTarget = nil
                // Through request(), not play(): the pending step may itself
                // need a bridge (standup into "look" must raise the shades).
                request(pending)
                return
            }
            if let next = animation.next {
                // A gesture finishing while the music plays settles back into
                // the groove, not into standing still.
                if next == "idle", grooveWanted { request("groove") } else { play(next) }
                return
            }
        }
        renderCurrentFrame()
    }

    // MARK: music

    private func musicChanged(_ playing: Bool) {
        log("music \(playing ? "playing" : "stopped")")
        let now = Date()
        guard playing else {
            musicStoppedAt = now
            if afterHop == "groove" { afterHop = nil }  // started and stopped mid-jump
            if Self.musicStates.contains(currentAnimation) || pendingTarget == "groove" {
                restoreAgentPose()
            }
            return
        }
        guard grooveEnabled, !isFocusing, !isBreathing else { return }
        // Claude needing you outranks the music; the groove starts once you've answered.
        guard !["glasses", "look"].contains(currentAnimation) else { return }
        cancelFidget()
        sitReason = nil
        request("groove")
        // Music back after a long silence: sometimes, a word about listening.
        if now.timeIntervalSince(musicStoppedAt) >= 30 * 60, Bool.random() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.canSpeakContextual(Date()) else { return }
                self.speakContextual(["listening"], at: Date())
            }
        }
    }

    @objc private func toggleGroove() {
        preferences.set(!grooveEnabled, forKey: Self.grooveKey)
        if grooveEnabled { musicChanged(music.isPlaying) }
        else if Self.musicStates.contains(currentAnimation) { restoreAgentPose() }
    }

    // MARK: perching

    /// Where he stands on a window. On its top edge when there's headroom under
    /// the menu bar, `perchSpot` of the way along, clear of the rounded
    /// corners. A maximized window has none, so he goes inside it — to the
    /// top-right corner under the toolbar by default, well away from the
    /// bottom where you type, or wherever you last put him in that app.
    private func perchOrigin(on frame: NSRect, app: String) -> NSPoint? {
        let size = spriteSize()
        let corner = 30.0
        guard frame.width - corner * 2 > size.width else { return nil }
        let below = Double(sprites.baseline) * pixel
        let area = NSScreen.screens
            .first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.maxY - 1)) }?.visibleFrame
        func onScreen(_ p: NSPoint) -> NSPoint {
            guard let area else { return p }
            return NSPoint(
                x: min(max(p.x, area.minX), area.maxX - size.width).rounded(),
                y: min(max(p.y, area.minY - below), area.maxY - size.height).rounded())
        }

        let onTop = frame.maxY - below
        if appSpots[app] == nil, let area, onTop + size.height <= area.maxY {
            let left = frame.minX + corner
            let right = frame.maxX - corner - size.width
            return onScreen(NSPoint(x: left + (right - left) * perchSpot, y: onTop))
        }
        let inside = insideRange(of: frame)
        let spot = appSpots[app] ?? [1, 1]
        return onScreen(NSPoint(
            x: inside.minX + inside.width * spot[0],
            y: inside.minY + inside.height * spot[1]))
    }

    /// The origins he can take inside a window: a margin all round, and the
    /// toolbar band at the top left clear.
    private func insideRange(of frame: NSRect) -> NSRect {
        let size = spriteSize()
        let margin = 16.0
        return NSRect(
            x: frame.minX + margin, y: frame.minY + margin,
            width: max(0, frame.width - margin * 2 - size.width),
            height: max(0, frame.height - margin - Self.toolbarBand - size.height))
    }

    private func updatePerch() {
        guard window.isVisible, !isDragging, hop == nil else { return }
        let id: CGWindowID
        let spot: NSPoint
        switch PerchTarget.current() {
        case .keep:
            return
        case .none:
            id = 0
            spot = savedOrigin(size: spriteSize())
            perchFrame = nil
            perchApp = nil
        case .window(let windowID, let frame, let app):
            guard let origin = perchOrigin(on: frame, app: app) else { return }
            id = windowID
            spot = origin
            perchFrame = frame
            perchApp = app
        }

        if id == perchedOn {
            perchCandidate = nil
            // Same window, moved or resized under him: ride along, no jump.
            if window.frame.origin != spot {
                perchFastUntil = Date().addingTimeInterval(0.6)
                move(to: spot)
            }
            return
        }
        // A different window. Give it a beat to settle before jumping.
        if perchCandidate?.id != id {
            perchCandidate = (id, Date())
            return
        }
        guard let since = perchCandidate?.since, Date().timeIntervalSince(since) >= 0.25 else { return }
        perchCandidate = nil
        perchedOn = id
        jump(to: spot)
    }

    private func move(to point: NSPoint) {
        window.setFrameOrigin(point)
        bubble.follow(window.frame, screen: window.screen)
    }

    /// A ballistic arc from here to there: linear across, a parabola up and
    /// down. Longer jumps take longer and go higher, within limits. A real
    /// jump charges up first and spins in the air; a short one just hops.
    private func jump(to point: NSPoint) {
        let from = window.frame.origin
        let distance = hypot(point.x - from.x, point.y - from.y)
        guard distance >= 8,  // a nudge, not a journey
            window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            move(to: point)
            return
        }
        // With the headphones on there's only the full jump; a short way, he glides.
        let phones = Self.musicStates.contains(currentAnimation)
        let leaps = Self.leapingPoses.contains(currentAnimation) && !isBreathing && !isFocusing
            && (!phones || distance >= Self.chargedJumpFrom)
        let charged = leaps && distance >= Self.chargedJumpFrom
        log("\(charged ? "jump" : leaps ? "hop" : "glide") from \(from) to \(point) [\(currentAnimation)]")
        // The charge runs to its glint; the last frame is held until liftoff.
        let chargeTicks = (sprites.animations["charge"]?.frames.dropLast().reduce(0) { $0 + $1.hold } ?? 0) + 2
        let windUp = charged ? Double(chargeTicks) / 30 : leaps ? 4.0 / 30 : 0
        let duration = charged ? min(1.0, 0.5 + distance / 2200) : min(0.6, 0.3 + distance / 1500)
        let loops = sprites.animations[currentAnimation]?.next == nil
        hop = Hop(
            from: from, to: point, start: Date().addingTimeInterval(windUp),
            duration: duration,
            height: charged ? min(170, 60 + distance * 0.15) : min(150, 24 + distance * 0.14),
            leaps: leaps, charged: charged,
            spins: max(1, Int((duration / 0.45).rounded())),
            rightward: point.x >= from.x,
            phones: phones,
            resume: leaps && loops && currentAnimation != "idle" ? currentAnimation : nil)
        if leaps {
            // Straight to the jump: nothing should bridge into it. Anything
            // already queued waits for the landing.
            afterHop = pendingTarget
            pendingTarget = nil
            play(charged ? (phones ? "charge-phones" : "charge") : "leap")
        }
    }

    private func stepHop() {
        guard var jump = hop else { return }
        let t = Date().timeIntervalSince(jump.start) / jump.duration
        guard t >= 0 else { return }  // still winding up
        if !jump.launched {
            jump.launched = true
            hop = jump
            if jump.charged { leaveBurst(at: window.frame) }
        }
        guard t < 1 else {
            hop = nil
            move(to: jump.to)
            let next = afterHop ?? jump.resume
            afterHop = nil
            if jump.leaps {
                play(jump.charged ? (jump.phones ? "land-phones" : "land") : "touchdown")
                pendingTarget = next  // the landing first, then this
            } else if let next {
                request(next)
            }
            return
        }
        if jump.charged {
            // Up with his arms raised, then tucked and turning a quarter at a
            // time — forward, in the direction of travel — upright as he lands.
            let quarters = jump.spins * 4
            let spin = min(quarters, Int((t - 0.12) / 0.88 * Double(quarters + 1)))
            let turn = jump.rightward ? spin % 4 : (4 - spin % 4) % 4
            show(jump.phones ? "flip-phones" : "flip", frame: t < 0.12 ? 0 : 1 + turn)
        }
        move(to: NSPoint(
            x: (jump.from.x + (jump.to.x - jump.from.x) * t).rounded(),
            y: (jump.from.y + (jump.to.y - jump.from.y) * t + jump.height * 4 * t * (1 - t)).rounded()))
    }

    /// Hold a particular frame, for motion the app drives itself.
    private func show(_ name: String, frame: Int) {
        guard let animation = sprites.animations[name], animation.frames.indices.contains(frame),
            currentAnimation != name || frameIndex != frame
        else { return }
        currentAnimation = name
        frameIndex = frame
        ticksOnFrame = 0
        renderCurrentFrame()
    }

    /// A burst of sparks and dust where he took off, in a window of its own
    /// that plays once and goes.
    private func leaveBurst(at rect: NSRect) {
        guard let frames = sprites.animations["puff"]?.frames, !frames.isEmpty else { return }
        let effect = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        effect.isOpaque = false
        effect.backgroundColor = .clear
        effect.hasShadow = false
        effect.level = .floating
        effect.ignoresMouseEvents = true
        effect.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let view = SpriteView(frame: NSRect(origin: .zero, size: rect.size))
        effect.contentView = view
        effects.append(effect)
        var at = 0.0
        for frame in frames {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                view.image = frame.image
                view.needsDisplay = true
                effect.orderFrontRegardless()
            }
            at += Double(frame.hold) / 30
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
            effect.orderOut(nil)
            self?.effects.removeAll { $0 === effect }
        }
    }

    /// Picked up mid-jump: drop the jump where he is, back on his feet.
    private func cancelHop() {
        guard let jump = hop else { return }
        hop = nil
        let next = afterHop ?? jump.resume
        afterHop = nil
        if jump.leaps { request(withMusic(next ?? "idle")) }
    }

    /// Let go after a drag. Standing on windows: dropped on a window's top
    /// edge, he stands on top of that app's windows, at that point along the
    /// edge; dropped inside a window, that spot is his in that app. Otherwise
    /// it's his new spot on the desktop.
    private func dropped() {
        guard perchEnabled, perchedOn != 0, let frame = perchFrame, let app = perchApp else {
            saveOrigin()
            return
        }
        let me = window.frame
        let feet = me.minY + Double(sprites.baseline) * pixel
        let corner = 30.0
        if abs(feet - frame.maxY) < 40, me.midX > frame.minX, me.midX < frame.maxX {
            let span = frame.width - corner * 2 - me.width
            if span > 0 {
                perchSpot = min(1, max(0, (me.minX - frame.minX - corner) / span))
                preferences.set(perchSpot, forKey: Self.perchSpotKey)
            }
            appSpots[app] = nil
        } else if frame.contains(NSPoint(x: me.midX, y: me.midY)) {
            let inside = insideRange(of: frame)
            appSpots[app] = [
                inside.width > 0 ? min(1, max(0, (me.minX - inside.minX) / inside.width)) : 1,
                inside.height > 0 ? min(1, max(0, (me.minY - inside.minY) / inside.height)) : 1,
            ]
        }
        preferences.set(appSpots, forKey: Self.appSpotsKey)
        perchedOn = nil  // look again, and go to it
    }

    @objc private func togglePerch() {
        preferences.set(!perchEnabled, forKey: Self.perchKey)
        perchedOn = nil
        perchCandidate = nil
        if !perchEnabled { jump(to: savedOrigin(size: spriteSize())) }
    }

    private func renderCurrentFrame() {
        guard let animation, frameIndex < animation.frames.count else { return }
        view.image = animation.frames[frameIndex].image
        view.needsDisplay = true
    }

    // MARK: Claude Code state

    private func pollState() {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: stateFile.path),
            let stamp = attrs[.modificationDate] as? Date
        else { return }
        guard stamp != lastStateStamp else { return }
        lastStateStamp = stamp

        guard let raw = try? String(contentsOf: stateFile, encoding: .utf8) else { return }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Not an animation: "breathe" in the state file starts a guided breath,
        // so hooks and scripts can offer one ("state.sh breathe").
        if name == "breathe" {
            if !isBreathing {
                cancelFidget()
                takeABreath()
            }
            return
        }
        // Also not an animation: "say <text>" borrows his voice — the quietest
        // notification endpoint on the machine. Local input from the user's own
        // scripts; capped so a runaway payload can't wallpaper the screen, and
        // never over a guided breath.
        if name.hasPrefix("say ") {
            let text = String(name.dropFirst(4))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(140)
            guard !text.isEmpty, !isBreathing, !inQuietHour, !isFocusing else { return }
            lastSaid = String(text)
            if Buddy.debug {
                FileHandle.standardError.write("say: \(text)\n".data(using: .utf8)!)
            }
            window.orderFrontRegardless()
            bubble.show(String(text), over: window.frame, pixel: pixel, screen: window.screen)
            return
        }
        guard !name.isEmpty, sprites.animations[name] != nil else { return }
        noteStateEvent(name)
        guard !isFocusing, !isBreathing else { return }
        // Seated for a long run: more of the same work is not a reason to stand.
        // Anything that ISN'T the same work (nod, glasses, idle) still is.
        if sitReason == "long", ["think", "stroke"].contains(name) { return }
        let pose = withMusic(name)
        // Re-triggering what's already playing would just make it stutter — and
        // a repeat that matches the pending target would hard-cut the bridge
        // that's currently carrying him there.
        guard pose != currentAnimation, pose != pendingTarget, pose != afterHop else { return }
        request(pose)
    }

    /// Contextual bookkeeping, run on every state-file event (even repeats).
    private func noteStateEvent(_ name: String) {
        let now = Date()
        if now.timeIntervalSince(lastStateEvent) > Self.ctxGap { activeSince = now }
        lastStateEvent = now

        // Real activity trumps fidgeting: cancel any gesture in flight. But the
        // re-arm depends on what the event MEANS — work coming in pushes the
        // next gesture out; coming to rest invites one soon.
        fidgetUntil = nil
        if name == "nod" || name == "idle" {
            nextFidgetAt = now.addingTimeInterval(.random(in: Self.fidgetAfterRest))
        } else {
            scheduleNextFidget()
        }

        if name == "glasses" || name == "look" {
            if waitingSince == nil {
                waitingSince = now
                saidWaitingLine = false
            }
        } else {
            waitingSince = nil
        }

        // Track how long one unbroken run of work has been going. Waiting
        // states (glasses/look) pause nothing — a permission prompt mid-task
        // is still the same task.
        let longRun = busySince.map { now.timeIntervalSince($0) >= Self.longTaskAfter } ?? false
        switch name {
        case "think", "stroke":
            if busySince == nil { busySince = now }
        case "nod", "idle":
            busySince = nil
        default:
            break
        }

        // A finished turn sometimes earns a Finishing line — but only sometimes,
        // and never twice inside the cooldown. Every Claude turn ends with a
        // Stop, and a buddy that comments on all of them stops being listened to.
        // The exception: a LONG run ending always deserves the word, cooldown or
        // not — if you waited half an hour for it, he has something to say.
        if name == "nod", longRun, canSpeakIgnoringCooldown() {
            speakContextual(["finishing"], at: now)
        } else if name == "nod", canSpeakContextual(now), Int.random(in: 0..<3) == 0 {
            speakContextual(["finishing"], at: now)
        } else if now.timeIntervalSince(activeSince) >= Self.ctxStretch, canSpeakContextual(now) {
            speakContextual(["stepping away"], at: now)
            activeSince = now  // the two-hour clock restarts after he says it
        }
    }

    /// The gate for lines important enough to skip the cooldown — still never
    /// in Silent mode, over another bubble, mid-breath, or while hidden.
    private func canSpeakIgnoringCooldown() -> Bool {
        Buddy.quietSecondsRange != nil && window.isVisible && !bubble.isVisible && !isBreathing && !isFocusing && companionWindow?.isVisible != true
            && !inQuietHour
    }

    // MARK: speech

    private func scheduleNextLine() {
        guard let range = Buddy.quietSecondsRange else { return }
        ticksUntilSpeaking = Int.random(in: range) * Self.ticksPerSecond
    }

    private func scheduleNextFidget() {
        nextFidgetAt = Date().addingTimeInterval(.random(in: Self.fidgetEvery))
    }

    /// For anything that takes over the body deliberately: forget the fidget in
    /// flight so its return-to-idle timer can't yank the new pose away.
    private func cancelFidget() {
        fidgetUntil = nil
        scheduleNextFidget()
    }

    /// Re-read on every line so edits to lines.txt land without a restart.
    private func lines() -> [String] {
        guard let raw = try? String(contentsOf: linesFile, encoding: .utf8) else {
            return Self.fallbackLines
        }
        let parsed = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return parsed.isEmpty ? Self.fallbackLines : parsed
    }

    /// Stable across launches, unlike hashValue (which is seeded per-process).
    /// FNV-1a; collisions would only mean a harmless extra reshuffle.
    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return String(h, radix: 16)
    }

    private func noteSpoken(_ line: String) {
        lastSaid = line
        preferences.set(line, forKey: "buddyLastThought")
        recentLines.append(line)
        if recentLines.count > Self.recentCap {
            recentLines.removeFirst(recentLines.count - Self.recentCap)
        }
        preferences.set(recentLines, forKey: Self.recentKey)
    }

    /// Deals from a shuffled deck rather than picking independently, so all of
    /// them play before any repeats — including across restarts. Reshuffles
    /// when lines.txt changes.
    private func speakLine() {
        let all = lines()
        let hash = Self.stableHash(all.joined(separator: "\n"))
        if !deckRestored {
            deckRestored = true
            if preferences.string(forKey: Self.deckSourceKey) == hash,
                let saved = preferences.stringArray(forKey: Self.deckKey),
                !saved.isEmpty
            {
                lineBag = saved
                bagSourceHash = hash
            }
        }
        if lineBag.isEmpty || hash != bagSourceHash {
            bagSourceHash = hash
            lineBag = all.shuffled()
        }
        guard let line = lineBag.popLast() else { return }
        preferences.set(lineBag, forKey: Self.deckKey)
        preferences.set(hash, forKey: Self.deckSourceKey)
        if Buddy.debug {
            FileHandle.standardError.write("deck: \(lineBag.count) left\n".data(using: .utf8)!)
        }
        noteSpoken(line)
        bubble.show(line, over: window.frame, pixel: pixel, screen: window.screen)
    }

    /// lines.txt grouped by its `# ── Theme ──` headers, keyed lowercase.
    /// Re-parsed on use, same as lines(), so edits land live.
    private func lineGroups() -> [String: [String]] {
        guard let raw = try? String(contentsOf: linesFile, encoding: .utf8) else { return [:] }
        var groups: [String: [String]] = [:]
        var current = ""
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") {
                if line.contains("──") {
                    let name = line
                        .replacingOccurrences(of: "#", with: "")
                        .replacingOccurrences(of: "─", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { current = name.lowercased() }
                }
                continue
            }
            if !line.isEmpty { groups[current, default: []].append(line) }
        }
        return groups
    }

    /// The break nudge. CGEventSource's idle clock is public API and needs no
    /// permissions — it reports time since input, never what was typed.
    private static let inputTypes: [CGEventType] = [
        .keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel,
    ]

    static func isNight(_ now: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: now)
        return hour >= Self.nightWindow.start || hour < Self.nightWindow.end
    }

    private static let greetDayKey = "buddyGreetDay"
    /// A gap in your activity this long makes the next activity an "arrival" —
    /// the thing a morning greeting is actually about.
    static var arrivalGap: TimeInterval = 4 * 60 * 60
    /// A gap this long — a trip, a weekend off the grid — is a return, and
    /// gets its own words instead of the ordinary morning line.
    static var returnGap: TimeInterval = 3 * 24 * 60 * 60
    /// The week's-end line: first quiet moment at or after this hour, this
    /// weekday (Calendar numbering, Sunday = 1, so Friday = 6). Once a week.
    static var weekEndWeekday = 6
    static var weekEndHour = 17

    /// Wall clock of the last poll that saw you active. Persisted (throttled),
    /// because the return greeting has to know how long you were gone across
    /// the restart that being gone usually involves.
    private var lastActiveAt: Date? = {
        let t = preferences.double(forKey: "buddyLastActive")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()
    private static let lastActiveKey = "buddyLastActive"
    private static let weekEndKey = "buddyWeekEnd"
    private var activePollsSinceSave = 0
    /// Wall clock of the previous poll, whatever it saw. A large gap here means
    /// the Mac was asleep — polls don't run while it sleeps.
    private var lastPollAt = Date()

    private func pollPresence() {
        guard !isFocusing else { return }
        let now = Date()
        // The machine sleeping IS a break, but the idle clock can't see it:
        // wake the Mac after eight hours and the very first poll reports
        // idle≈0 (you just touched the keyboard), so the away-branch below
        // never runs and yesterday's activeSeconds would still be on the books.
        if now.timeIntervalSince(lastPollAt) >= Self.breakReset {
            activeSeconds = 0
        }
        lastPollAt = now

        let idle = Self.inputTypes
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .infinity

        if idle < 60 {
            activeSeconds += 1

            // You're back from being away: he finishes nothing, he just gets
            // up. Only for away-sits — a night sit means he's sitting WITH
            // you, and any other sit is yours (or a task's) to end.
            if sitReason == "away", Self.sittingStates.contains(currentAnimation), !isBreathing {
                sitReason = nil
                request("idle")
            }

            // An arrival is activity after a real gap (or the first since
            // launch) — NOT the date flipping at midnight under your hands.
            let gap = lastActiveAt.map { now.timeIntervalSince($0) }
            if gap.map({ $0 >= Self.arrivalGap }) ?? true { greetTheMorning(after: gap ?? 0) }
            lastActiveAt = now
            activePollsSinceSave += 1
            if activePollsSinceSave >= 60 {   // once a minute is plenty for a three-day question
                activePollsSinceSave = 0
                preferences.set(now.timeIntervalSince1970, forKey: Self.lastActiveKey)
            }
            greetTheWeekEnd(now)

            // The break nudge belongs here, while you're present — firing it
            // into an empty room both wasted the line and reset the clock.
            if activeSeconds >= Self.breakEvery, canSpeakContextual(now) {
                speakContextual(["the world"], at: now)
                activeSeconds = 0
            }
        } else {
            if idle >= Self.breakReset {
                activeSeconds = 0  // you took a real break; the clock restarts
            }
            // Nobody's here. He has his own practice.
            if idle >= Self.meditateAfter, currentAnimation == "idle" {
                sitReason = "away"
                request("meditate")
            }
        }

        // Late: idle becomes the seated pose — he sits with you, not at you.
        // Events still stand him up (the sit-exit bridge handles it), and he
        // settles back down when things go quiet again.
        if Self.isNight(now), currentAnimation == "idle", fidgetUntil == nil, !isBreathing {
            sitReason = "night"
            request("meditate")
        } else if !Self.isNight(now), sitReason == "night",
            Self.sittingStates.contains(currentAnimation), !isBreathing
        {
            sitReason = nil
            request("idle")  // morning: back on his feet
        }

        // Claude has been at ONE task a long time: stroking on loop for forty
        // minutes reads as manic. He sits down and keeps watch instead.
        if let since = busySince, ["think", "stroke"].contains(currentAnimation),
            now.timeIntervalSince(since) >= Self.longTaskAfter
        {
            sitReason = "long"
            request("meditate")
        }

        // A busy pose with no state event for this long is a dead session —
        // Claude Code crashed or the terminal was killed, so no Stop ever came.
        // He shouldn't work the beard (or keep a seated vigil) for a ghost.
        if now.timeIntervalSince(lastStateEvent) >= Self.busyStaleAfter {
            if ["think", "stroke"].contains(currentAnimation) {
                busySince = nil
                request("idle")
            } else if sitReason == "long" {
                busySince = nil
                sitReason = nil
                request("idle")
            }
        }
    }

    /// One line for your first arrival of the day, leaning toward beginnings.
    /// The day is only marked once he actually says it, so a blocked attempt
    /// (bubble up, cooldown) retries on a later poll instead of skipping a day.
    /// `gap` is how long you'd been away. Past `returnGap` it stops being a
    /// morning and becomes a return, which has its own things to say.
    private func greetTheMorning(after gap: TimeInterval) {
        let day = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current,
            formatOptions: [.withFullDate])
        guard preferences.string(forKey: Self.greetDayKey) != day else { return }
        let now = Date()
        guard canSpeakContextual(now) else { return }
        preferences.set(day, forKey: Self.greetDayKey)
        let groups = gap >= Self.returnGap ? ["return"] : ["beginnings and endings", "practice"]
        speakContextual(groups, at: now)
    }

    /// Late on a Friday, the first moment he's idle and you're there: one line
    /// about the week being over. Once per week; a busy Friday evening that
    /// never goes quiet simply gets none.
    private func greetTheWeekEnd(_ now: Date) {
        let cal = Calendar.current
        guard cal.component(.weekday, from: now) == Self.weekEndWeekday,
              cal.component(.hour, from: now) >= Self.weekEndHour,
              currentAnimation == "idle", pendingTarget == nil else { return }
        let week = "\(cal.component(.yearForWeekOfYear, from: now))-W\(cal.component(.weekOfYear, from: now))"
        guard preferences.string(forKey: Self.weekEndKey) != week,
              canSpeakContextual(now) else { return }
        preferences.set(week, forKey: Self.weekEndKey)
        speakContextual(["week's end"], at: now)
    }

    private func canSpeakContextual(_ now: Date) -> Bool {
        Buddy.quietSecondsRange != nil && window.isVisible && !bubble.isVisible && !isFocusing && companionWindow?.isVisible != true
            && !isBreathing  // never interject between "Hold…" and "Out…"
            && !inQuietHour
            && now.timeIntervalSince(lastContextual) >= Self.ctxCooldown
    }

    /// A line from the named theme groups — the moment picks the theme. Falls
    /// back to the whole deck if the groups aren't in the file any more.
    private func speakContextual(_ groupNames: [String], at now: Date) {
        let groups = lineGroups()
        let pool = groupNames.flatMap { groups[$0] ?? [] }
        let full = pool.isEmpty ? lines() : pool
        // Prefer lines he hasn't said lately. The pools are small, so when
        // everything in one has been said recently, saying the least-recent
        // beats going silent — but never the same-day déjà vu of pure chance.
        let fresh = full.filter { !recentLines.contains($0) }
        let line: String?
        if !fresh.isEmpty {
            line = fresh.randomElement()
        } else {
            line = full.min { a, b in
                (recentLines.lastIndex(of: a) ?? -1) < (recentLines.lastIndex(of: b) ?? -1)
            }
        }
        guard let line else { return }
        if Buddy.debug {
            FileHandle.standardError.write("ctx \(groupNames): \(line)\n".data(using: .utf8)!)
        }
        noteSpoken(line)
        bubble.show(line, over: window.frame, pixel: pixel, screen: window.screen)
        lastContextual = now
        // He just spoke; push the random line back out so they don't stack.
        scheduleNextLine()
    }

    // MARK: updates

    private var autoUpdateEnabled: Bool {
        preferences.object(forKey: Self.autoUpdateKey) as? Bool ?? true
    }

    private func log(_ message: String) {
        guard Buddy.debug else { return }
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    }

    /// True from announcing an update until its installer reports failure.
    /// (Success kills this process, so there is no "success" transition.)
    private var updateInFlight = false
    /// A version whose install already failed once — retried silently on later
    /// checks, never re-announced. "New version. Updating." every six hours
    /// while nothing changes is worse than no updater at all.
    private var announcedFailedVersion: String?

    private func checkForUpdates(userAsked: Bool) {
        log(
            "update check: asked=\(userAsked) auto=\(autoUpdateEnabled) "
                + "managed=\(isManagedInstall) local=\(localVersion)")
        guard userAsked || (autoUpdateEnabled && isManagedInstall) else {
            log("update check: skipped")
            return
        }
        guard !updateInFlight else { return }
        // Never yank him out from under a guided breath; the next check gets it.
        if (isBreathing || isFocusing), !userAsked { return }
        Updater.fetchLatest { [weak self] remote in
            guard let self else { return }
            self.log("update check: remote=\(remote ?? "nil")")
            guard let remote else {
                if userAsked { self.say("Couldn't reach the update server.") }
                return
            }
            guard Updater.isNewer(remote, than: self.localVersion) else {
                if userAsked { self.say("You're on the latest. \(self.localVersion)") }
                return
            }
            guard self.isManagedInstall else {
                if userAsked {
                    self.say(Bundle.main.bundleURL.pathExtension == "app"
                        ? "\(remote) is out. Visit rick-buddy.netlify.app to update."
                        : "\(remote) is out. Developer build — git pull.")
                }
                return
            }
            guard !self.updateInFlight else { return }
            self.updateInFlight = true
            if userAsked || self.announcedFailedVersion != remote {
                self.say("New version, \(remote). Updating.")
            }
            // Let the bubble land before the installer stops us.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                Updater.runInstaller { message in
                    guard let self else { return }
                    self.updateInFlight = false
                    // Tell the user once per broken version; retries stay silent.
                    let alreadyAnnounced = self.announcedFailedVersion == remote
                    self.announcedFailedVersion = remote
                    self.log("update failed for \(remote)")
                    if userAsked || !alreadyAnnounced { self.say(message) }
                }
            }
        }
    }

    /// Say something specific, rather than a line from the deck.
    private func say(_ text: String) {
        window.orderFrontRegardless()
        bubble.show(text, over: window.frame, pixel: pixel, screen: window.screen)
    }

    // MARK: guided breath

    /// A slow minute together: he sits, and the bubble paces four rounds of
    /// 4-4-6. No streaks, no history, no reminder to do it again.
    @objc func takeABreath() {
        if isBreathing {
            cancelBreath(standUp: true)
            return
        }
        finishFocus(announce: false)
        cancelFidget()
        window.orderFrontRegardless()  // a hidden Rick pacing breaths is just noise
        request("meditate")
        var at = 1.6  // let him get seated first
        var steps: [(String, Double)] = []
        for _ in 0..<4 { steps += [("In…", 4), ("Hold…", 4), ("Out…", 6)] }
        for (text, length) in steps {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.bubble.show(
                    text, over: self.window.frame, pixel: self.pixel,
                    screen: self.window.screen, duration: length - 0.4)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + at, execute: work)
            breathWork.append(work)
            at += length
        }
        let done = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.breathWork.removeAll()
            self.restoreAgentPose()  // back to the current session, without chatter
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + at + 0.5, execute: done)
        breathWork.append(done)
    }

    private func cancelBreath(standUp: Bool) {
        guard isBreathing else { return }
        breathWork.forEach { $0.cancel() }
        breathWork.removeAll()
        bubble.hide()
        if standUp { restoreAgentPose() }
    }

    // MARK: companion panel, quiet sits, and thoughts

    private var sessionTitle: String {
        guard let session = sessions.first else { return (hooksWired || codexHooksWired) ? "Waiting for session activity" : "Keeping you company" }
        switch session.effectivePhase(at: Date().timeIntervalSince1970) {
        case "waiting": return "\(session.agentName) needs you"
        case "working": return "\(session.agentName) is working"
        case "ready": return "Ready for your review"
        case "unknown": return "Check your \(session.agentName) session"
        default: return "\(session.agentName) is connected"
        }
    }

    private func pollSessions() {
        let directory = stateFile.deletingLastPathComponent().appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let paths = Set(files.filter { $0.pathExtension == "json" }.map(\.path))
        sessionCache = sessionCache.filter { paths.contains($0.key) }
        for file in files where file.pathExtension == "json" {
            guard let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            if sessionCache[file.path]?.0 == stamp { continue }
            guard let data = try? Data(contentsOf: file), data.count < 8192,
                  let session = try? JSONDecoder().decode(AgentSession.self, from: data) else {
                sessionCache.removeValue(forKey: file.path); continue
            }
            sessionCache[file.path] = (stamp, session)
        }
        let all = sessionCache.values.map { $0.1 }
        let now = Date().timeIntervalSince1970
        sessions = AgentSession.ordered(all, at: now, acknowledged: acknowledged)
        let currentIDs = Set(all.map(\.id))
        acknowledged = acknowledged.filter { currentIDs.contains($0.key) }
        let signature = sessions.first.map { "\($0.id):\($0.effectivePhase(at: now)):\($0.updated)" } ?? "none"
        guard signature != lastSessionEvent else { return }
        lastSessionEvent = signature
        guard let first = sessions.first else {
            waitingSince = nil; busySince = nil
            if !isFocusing && !isBreathing { request(withMusic("idle")) }
            return
        }
        let event = agentPose(first)
        noteStateEvent(event)
        guard !isFocusing, !isBreathing else { return }
        let pose = withMusic(event)
        if pose != currentAnimation && pose != pendingTarget && pose != afterHop { request(pose) }
    }

    private func agentPose(_ session: AgentSession) -> String {
        switch session.effectivePhase(at: Date().timeIntervalSince1970) {
        case "waiting": return "glasses"
        case "working": return session.event == "UserPromptSubmit" ? "think" : "stroke"
        case "ready": return "nod"
        default: return "idle"
        }
    }

    private func restoreAgentPose() {
        if isFocusing { request("meditate") }
        else { request(withMusic(sessions.first.map(agentPose) ?? "idle")) }
    }

    @objc private func openCompanion() {
        // Wait for a right-click settings menu to finish dismissing.
        DispatchQueue.main.async { [weak self] in self?.presentCompanion() }
    }

    private func presentCompanion() {
        log("open companion")
        if companionWindow?.isVisible == true { companionWindow?.close(); return }
        guard let button = statusItem?.button else { return }
        if companionPanel == nil {
            let panel = CompanionPanel()
            panel.icon = sprites.animations["idle"]?.frames.first?.image
            panel.onAction = { [weak self] action in self?.performCompanionAction(action) }
            companionPanel = panel
            _ = panel.view
        }
        if lastSaid.isEmpty { speakLine() }
        refreshPanel()
        NSApp.activate(ignoringOtherApps: true)
        guard let content = companionPanel else { return }
        content.view.layoutSubtreeIfNeeded()
        if companionWindow == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 346, height: 520),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Rick"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.contentViewController = content
            companionWindow = panel
        }
        if let panel = companionWindow {
            panel.setContentSize(NSSize(width: 346, height: content.view.fittingSize.height))
            let area = (button.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            let anchor = button.window?.frame.midX ?? area.maxX
            panel.setFrameOrigin(NSPoint(x: min(max(area.minX + 12, anchor - panel.frame.width / 2), area.maxX - panel.frame.width - 12),
                y: area.maxY - panel.frame.height - 12))
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func performCompanionAction(_ action: String) {
        switch action {
        case "focus": toggleFocus()
        case "breath": takeABreath()
        case "quiet": toggleQuietHour()
        case "keep": keepThought()
        case "picture": copyThoughtPicture()
        case "saved": companionWindow?.close(); showSavedThoughts()
        case "review":
            for session in sessions where session.phase == "ready" { acknowledged[session.id] = session.updated }
            preferences.set(acknowledged, forKey: "buddyReviewed")
            pollSessions()
        case "settings":
            companionWindow?.close()
            if let button = statusItem?.button {
                buildMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            }
        default: break
        }
        refreshPanel()
    }

    private func refreshPanel() {
        let phase = sessions.first?.effectivePhase(at: Date().timeIntervalSince1970)
        let title: String
        switch phase {
        case "waiting": title = " Needs you"
        case "ready": title = " Ready"
        case "working": title = " Working"
        case "unknown": title = " Check session"
        default: title = ""
        }
        statusItem?.button?.title = showStatusLabel ? title : ""
        statusItem?.button?.toolTip = "Rick · \(sessionTitle)"
        guard let panel = companionPanel else { return }
        panel.statusLabel.stringValue = sessionTitle
        let details = sessions.prefix(4).map { session in
            let detail = session.effectivePhase(at: Date().timeIntervalSince1970) == "unknown"
                ? "No recent activity; status unknown" : session.detail
            return "\(session.agentName) · \(session.project) · \(detail)"
        }
        panel.detailLabel.stringValue = details.isEmpty
            ? (codexHooksWired ? "Open a new session after trusting Rick’s hooks in Codex /hooks." : hooksWired ? "Open a new Claude Code session to see its status." : "Works on his own. Connect Claude Code or Codex in Settings.")
            : details.joined(separator: "\n") + (sessions.count > 4 ? "\n+\(sessions.count - 4) more sessions" : "")
        panel.thoughtLabel.stringValue = lastSaid.isEmpty ? "Here when you need me." : "“\(lastSaid)”"
        panel.keepButton.title = keptThoughts.contains(lastSaid) ? "Thought kept ✓" : "Keep this thought"
        panel.keepButton.isEnabled = !lastSaid.isEmpty && !keptThoughts.contains(lastSaid)
        panel.focusButton.title = isFocusing
            ? "End our sit · \(max(1, Int(ceil(focusUntil!.timeIntervalSinceNow / 60)))) min left"
            : "Sit with me · 25 minutes"
        panel.breathButton.title = isBreathing ? "End our breath" : "Take a breath · 1 minute"
        panel.quietButton.title = inQuietHour ? "End quiet hour" : "A little quiet · 1 hour"
        panel.reviewButton.isHidden = !sessions.contains { $0.phase == "ready" }
    }

    @objc private func toggleFocus() {
        if focusUntil != nil { finishFocus(announce: false); return }
        cancelBreath(standUp: false)
        cancelFidget()
        focusUntil = Date().addingTimeInterval(ProcessInfo.processInfo.environment["RUBIN_CTX_FAST"] == "1" ? 12 : 25 * 60)
        preferences.set(focusUntil!.timeIntervalSince1970, forKey: "buddyFocusUntil")
        window.orderFrontRegardless()
        request("meditate")
        say("Just this one thing. I’ll sit with you.")
    }

    private func pollFocus() {
        if let until = focusUntil, until <= Date() { finishFocus(announce: true) }
    }

    private func finishFocus(announce: Bool) {
        guard focusUntil != nil else { return }
        focusUntil = nil
        preferences.removeObject(forKey: "buddyFocusUntil")
        restoreAgentPose()
        scheduleNextLine(); scheduleNextFidget()
        if announce && window.isVisible && !inQuietHour && Buddy.quietSecondsRange != nil {
            say("That was a little space for the work. Take a breath.")
        }
    }

    @objc private func keepThought() {
        guard !lastSaid.isEmpty else { return }
        var thoughts = keptThoughts
        if !thoughts.contains(lastSaid) { thoughts.insert(lastSaid, at: 0); keptThoughts = thoughts }
        companionPanel?.noticeLabel.stringValue = "Saved on this Mac."
        refreshPanel()
    }

    private func thoughtPicture(_ text: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 1000, height: 650))
        image.lockFocus()
        PAPER.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 650).fill()
        let quote = "“\(text)”" as NSString
        var fontSize: CGFloat = 38
        while fontSize > 16 {
            let font = NSFont(name: "Georgia", size: fontSize) ?? .systemFont(ofSize: fontSize)
            let height = quote.boundingRect(with: NSSize(width: 690, height: 2000),
                options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
            if height <= 330 { break }
            fontSize -= 2
        }
        let font = NSFont(name: "Georgia", size: fontSize) ?? .systemFont(ofSize: fontSize)
        quote.draw(in: NSRect(x: 80, y: 210, width: 710, height: 330),
                   withAttributes: [.font: font, .foregroundColor: INK])
        if let sprite = sprites.animations["idle"]?.frames.first?.image {
            sprite.draw(in: NSRect(x: 810, y: 90, width: 104, height: 136),
                from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: false, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        }
        ("A little company for the work." as NSString).draw(at: NSPoint(x: 80, y: 112),
            withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: INK])
        ("rick-buddy.netlify.app" as NSString).draw(at: NSPoint(x: 80, y: 78),
            withAttributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: INK.withAlphaComponent(0.7)])
        image.unlockFocus()
        return image
    }

    private func copyPicture(_ text: String) {
        let image = thoughtPicture(text)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        NSPasteboard.general.setData(tiff, forType: .tiff)
        companionPanel?.noticeLabel.stringValue = "Picture copied. Paste it wherever you like."
    }

    @objc private func copyThoughtPicture() {
        guard !lastSaid.isEmpty else { return }
        copyPicture(lastSaid)
    }

    @objc private func showSavedThoughts() {
        if savedWindow == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 460),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Saved thoughts"
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 360, height: 260)
            panel.center()
            savedWindow = panel
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let thoughts = keptThoughts
        if thoughts.isEmpty {
            stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "A thought worth keeping will find you. Choose Keep This Thought in Rick’s panel."))
        }
        for (index, thought) in thoughts.enumerated() {
            let label = NSTextField(wrappingLabelWithString: thought)
            label.font = NSFont(name: "Georgia", size: 17) ?? .systemFont(ofSize: 17)
            label.isSelectable = true
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
            let row = NSStackView()
            for (title, action) in [("Copy text", #selector(copySaved(_:))), ("Copy picture", #selector(pictureSaved(_:))), ("Remove", #selector(removeSaved(_:)))] {
                let button = NSButton(title: title, target: self, action: action)
                button.tag = index; button.bezelStyle = .rounded
                row.addArrangedSubview(button)
            }
            stack.addArrangedSubview(row)
        }
        savedWindow?.contentView = scroll
        NSApp.activate(ignoringOtherApps: true)
        savedWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func copySaved(_ sender: NSButton) {
        guard keptThoughts.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(keptThoughts[sender.tag], forType: .string)
        sender.title = "Copied"
    }
    @objc private func pictureSaved(_ sender: NSButton) {
        guard keptThoughts.indices.contains(sender.tag) else { return }
        copyPicture(keptThoughts[sender.tag]); sender.title = "Copied"
    }
    @objc private func removeSaved(_ sender: NSButton) {
        var thoughts = keptThoughts
        guard thoughts.indices.contains(sender.tag) else { return }
        thoughts.remove(at: sender.tag); keptThoughts = thoughts
        showSavedThoughts(); refreshPanel()
    }
    @objc private func setTextSize(_ sender: NSMenuItem) {
        preferences.set(sender.tag, forKey: "buddyTextSize")
        bubble.hide()
    }
    @objc private func toggleStatusLabel() {
        preferences.set(!showStatusLabel, forKey: "buddyShowStatus")
        refreshPanel()
    }

    // MARK: menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = sprites.menuIcon {
            item.button?.image = icon
        } else {
            item.button?.title = "R"
        }
        item.button?.toolTip = "Rick"
        let menu = NSMenu()
        menu.delegate = self  // rebuilt on open so the check marks are current
        item.button?.target = self
        item.button?.action = #selector(openCompanion)
        statusItem = item
    }

    /// NSMenuDelegate — rebuild just before it's shown.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        for item in buildMenu().items.map({ $0.copy() as! NSMenuItem }) {
            menu.addItem(item)
        }
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false, tag: Int = 0)
        -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        item.tag = tag
        return item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(item("Open Companion", #selector(openCompanion)))
        menu.addItem(item(isFocusing ? "End Our Sit" : "Sit with Me · 25 Minutes", #selector(toggleFocus)))
        menu.addItem(item("Saved Thoughts", #selector(showSavedThoughts)))
        menu.addItem(.separator())
        menu.addItem(
            item(window.isVisible ? "Hide Rick" : "Show Rick", #selector(toggleVisible)))
        menu.addItem(item("Bring Him Back", #selector(bringBackAndShow)))
        menu.addItem(item("Stand on Your Window", #selector(togglePerch), on: perchEnabled))
        menu.addItem(item("Headphones with Music", #selector(toggleGroove), on: grooveEnabled))
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for (i, choice) in Self.sizeChoices.enumerated() {
            sizeMenu.addItem(
                item(
                    choice.0, #selector(setSize(_:)),
                    on: abs(choice.1 - requestedScale) < 0.01, tag: i))
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let textMenu = NSMenu()
        for size in [13, 15, 18, 22] {
            let current = preferences.integer(forKey: "buddyTextSize")
            textMenu.addItem(item("\(size) pt", #selector(setTextSize(_:)),
                on: size == (current == 0 ? 15 : current), tag: size))
        }
        let textItem = NSMenuItem(title: "Text Size", action: nil, keyEquivalent: "")
        textItem.submenu = textMenu; menu.addItem(textItem)
        menu.addItem(item("Show Agent Status in Menu Bar", #selector(toggleStatusLabel), on: showStatusLabel))
        let chatterMenu = NSMenu()
        for (i, choice) in Self.chatterChoices.enumerated() {
            chatterMenu.addItem(
                item(
                    choice.0, #selector(setChatter(_:)),
                    on: choice.1 == Buddy.quietSecondsRange, tag: i))
        }
        let chatterItem = NSMenuItem(title: "Chatter", action: nil, keyEquivalent: "")
        chatterItem.submenu = chatterMenu
        menu.addItem(chatterItem)

        if inQuietHour {
            let left = max(1, Int(quietUntil.timeIntervalSinceNow / 60) + 1)
            menu.addItem(item("End Quiet (\(left)m left)", #selector(toggleQuietHour), on: true))
        } else {
            menu.addItem(item("Quiet for an Hour", #selector(toggleQuietHour)))
        }

        let poseMenu = NSMenu()
        for name in sprites.animations.keys.sorted() where sprites.animations[name]?.isInternal != true {
            let entry = item(
                name.capitalized, #selector(selectAnimation(_:)), on: name == currentAnimation)
            entry.representedObject = name
            poseMenu.addItem(entry)
        }
        let poseItem = NSMenuItem(title: "Pose", action: nil, keyEquivalent: "")
        poseItem.submenu = poseMenu
        menu.addItem(poseItem)

        if !lastSaid.isEmpty {
            // Clickable: copies the full line. People share these — make it easy.
            let shown = lastSaid.count > 58 ? lastSaid.prefix(57) + "…" : Substring(lastSaid)
            let said = item(
                "He said: \u{201C}\(shown)\u{201D} — copy", #selector(copyLastSaid))
            menu.addItem(said)
        }
        menu.addItem(item("Keep This Thought", #selector(keepThought)))
        menu.addItem(item("Copy Thought Picture", #selector(copyThoughtPicture)))
        menu.addItem(item("Say Something", #selector(saySomething)))
        menu.addItem(item("Take a Breath", #selector(takeABreath), on: isBreathing))
        menu.addItem(.separator())
        menu.addItem(
            item("Follow Claude Code", #selector(toggleFollowClaude), on: hooksWired))
        menu.addItem(item("Follow Codex", #selector(toggleFollowCodex), on: codexHooksWired))
        menu.addItem(item("Start at Login", #selector(toggleLoginItem), on: LoginItem.isEnabled))

        let versionLabel = NSMenuItem(
            title: isManagedInstall
                ? "Version \(localVersion)" : "Version \(localVersion) (\(Bundle.main.bundleURL.pathExtension == "app" ? "standalone" : "dev build"))",
            action: nil, keyEquivalent: "")
        versionLabel.isEnabled = false
        menu.addItem(versionLabel)
        menu.addItem(item("Check for Updates", #selector(checkNow)))
        menu.addItem(item("Report a Problem", #selector(reportProblem)))
        if isManagedInstall {
            menu.addItem(item("Auto-Update", #selector(toggleAutoUpdate), on: autoUpdateEnabled))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Rick", #selector(quit)))
        return menu
    }

    /// Opens a GitHub issue pre-filled with the diagnostics a report needs —
    /// the reporter shouldn't have to know what a version string is or where
    /// the log lives.
    @objc private func reportProblem() {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let body = """
            **What happened:**

            **What I expected:**

            ---
            Rick \(localVersion) · macOS \(os)
            If he crashed or vanished, attach `~/Library/Logs/rubin-buddy.log` — \
            it has no personal contents, only his own errors.
            """
        var parts = URLComponents(string: "https://github.com/\(Updater.repo)/issues/new")!
        parts.queryItems = [URLQueryItem(name: "body", value: body)]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }

    @objc private func checkNow() {
        say("Checking...")
        checkForUpdates(userAsked: true)
    }

    @objc private func toggleAutoUpdate() {
        preferences.set(!autoUpdateEnabled, forKey: Self.autoUpdateKey)
    }

    @objc private func toggleVisible() {
        if window.isVisible {
            bubble.hide()
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    private func bringBack(persist: Bool) {
        bubble.hide()
        perchedOn = nil  // standing on windows, he finds his window again from here
        window.setFrameOrigin(defaultOrigin(size: spriteSize()))
        if persist { saveOrigin() }
    }

    @objc private func bringBackAndShow() {
        bringBack(persist: true)  // the menu click is intentional; remember it
        window.orderFrontRegardless()
        request(isFocusing ? "meditate" : "glasses")
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard Self.sizeChoices.indices.contains(sender.tag) else { return }
        applyScale(Self.sizeChoices[sender.tag].1)
    }

    /// One click before a call; restores itself. The failure mode of Silent
    /// was forgetting to turn him back on — this can't be forgotten.
    @objc private func toggleQuietHour() {
        quietUntil = inQuietHour ? .distantPast : Date().addingTimeInterval(60 * 60)
        preferences.set(quietUntil.timeIntervalSince1970, forKey: Self.quietKey)
        bubble.hide()
    }

    @objc private func setChatter(_ sender: NSMenuItem) {
        guard Self.chatterChoices.indices.contains(sender.tag) else { return }
        let choice = Self.chatterChoices[sender.tag]
        Buddy.quietSecondsRange = choice.1
        preferences.set(choice.0, forKey: Self.chatterKey)
        scheduleNextLine()
    }

    @objc private func selectAnimation(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        finishFocus(announce: false)
        cancelFidget()
        request(name)
    }

    @objc private func copyLastSaid() {
        guard !lastSaid.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastSaid, forType: .string)
    }

    @objc private func saySomething() {
        window.orderFrontRegardless()
        speakLine()
        scheduleNextLine()
    }

    // MARK: Claude Code hooks

    private var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// The hooks script tags every entry it writes with "rubin-buddy", which is
    /// also how it recognises its own entries to remove — so presence of the
    /// marker is exactly "wired".
    private var hooksWired: Bool {
        (try? String(contentsOf: claudeSettingsURL, encoding: .utf8))?
            .contains("rubin-buddy") ?? false
    }

    /// One click instead of a trip to the terminal. Shells out to the same
    /// hooks.sh the terminal path uses, so there is exactly one implementation
    /// of the settings merge.
    @objc private func toggleFollowClaude() {
        let script = appDirectory.appendingPathComponent("hooks.sh").path
        guard FileManager.default.fileExists(atPath: script) else {
            say("Can't find hooks.sh. Reinstall me.")
            return
        }
        let wasWired = hooksWired
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = wasWired ? [script, "--remove"] : [script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            say("Couldn't run it. Try ~/.rubin-buddy/hooks.sh")
            return
        }
        // Believe the file, not the exit code.
        switch (wasWired, hooksWired) {
        case (false, true): say("Following. Open a fresh session.")
        case (true, false): say("Not following.")
        default: say("That didn't take. Try ~/.rubin-buddy/hooks.sh")
        }
    }

    private var codexSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
    }
    private var codexHooksWired: Bool {
        (try? String(contentsOf: codexSettingsURL, encoding: .utf8))?.contains("# rubin-buddy") ?? false
    }
    @objc private func toggleFollowCodex() {
        let script = appDirectory.appendingPathComponent("hooks.sh").path
        guard FileManager.default.fileExists(atPath: script) else { say("Reinstall me to connect Codex."); return }
        let wasWired = codexHooksWired
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = wasWired ? [script, "--codex", "--remove"] : [script, "--codex"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit() }
        catch { say("Couldn’t connect. Try ~/.rubin-buddy/hooks.sh --codex"); return }
        if task.terminationStatus != 0 { say("Couldn’t update Codex hooks. Your settings were kept."); return }
        if wasWired { say("No longer following Codex.") }
        else {
            say("Almost there. Open /hooks in Codex and trust Rick’s hooks, then start a new session.")
            let alert = NSAlert()
            alert.messageText = "One more step in Codex"
            alert.informativeText = "Rick’s hooks are configured. In Codex, open /hooks to review and trust them, then open a new session. Rick only keeps session status and the project folder name; he does not save prompts or transcripts."
            alert.addButton(withTitle: "Got it")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(
            !LoginItem.isEnabled,
            executable: Bundle.main.executableURL?.path ?? appDirectory.appendingPathComponent("buddy").path,
            logPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/rubin-buddy.log").path)
    }

    @objc private func quit() {
        if !perchEnabled { saveOrigin() }  // a window's edge isn't his spot
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())
let env = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser
let here = appDirectory

let version =
    (try? String(contentsOf: here.appendingPathComponent("VERSION"), encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"

if args.contains("--version") || args.contains("-v") {
    print("rubin-buddy \(version)")
    exit(0)
}
if args.contains("--help") || args.contains("-h") {
    print(
        """
        rubin-buddy \(version) — an 8-bit desktop buddy.

          buddy [framesDir] [scale]

          --version   print the version
          --help      this

        Environment: RUBIN_SCALE, RUBIN_CHATTER (e.g. 150-420), RUBIN_LINES,
        RUBIN_STATE, RUBIN_FRAMES, RUBIN_DEBUG=1, RUBIN_UPDATE_DELAY.

        Settings live in the menu bar. https://github.com/Gitmealez/rubin-buddy
        """)
    exit(0)
}

// Flags are handled above; anything left that starts with '-' isn't a path, and
// treating it as one produced a baffling "manifest.json not found" error.
let positional = args.filter { !$0.hasPrefix("-") }

let framesDir: URL = {
    if let arg = positional.first { return URL(fileURLWithPath: arg) }
    if let fromEnv = env["RUBIN_FRAMES"] { return URL(fileURLWithPath: fromEnv) }
    return here.appendingPathComponent("frames")
}()

// 2.5 lands on exactly 5 device pixels per sprite pixel on a 2x display.
Buddy.scaleFromLaunch = positional.count > 1 || env["RUBIN_SCALE"] != nil
let scale = max(
    1.0, Double(positional.count > 1 ? positional[1] : env["RUBIN_SCALE"] ?? "") ?? 2.5)

let stateFile: URL = {
    if let fromEnv = env["RUBIN_STATE"] { return URL(fileURLWithPath: fromEnv) }
    return home.appendingPathComponent(".rubin-buddy/state")
}()

let linesFile: URL = {
    if let fromEnv = env["RUBIN_LINES"] { return URL(fileURLWithPath: fromEnv) }
    return here.appendingPathComponent("lines.txt")
}()

Buddy.debug = env["RUBIN_DEBUG"] == "1"

// Testing only: contextual triggers are minutes-to-hours apart by design, which
// makes them unverifiable in a sitting. This compresses them to seconds.
if env["RUBIN_CTX_FAST"] == "1" {
    Buddy.ctxCooldown = 12
    Buddy.ctxWait = 8
    Buddy.ctxStretch = 40
    Buddy.ctxGap = 20
    Buddy.fidgetEvery = 5...9
    Buddy.fidgetLength = 3...5
    Buddy.fidgetAfterRest = 2...4
    Buddy.breakEvery = 30
    Buddy.breakReset = 10
    Buddy.meditateAfter = 15
    Buddy.busyStaleAfter = 60
    Buddy.arrivalGap = 40
    Buddy.returnGap = 90
    Buddy.weekEndWeekday = Calendar.current.component(.weekday, from: Date())
    Buddy.weekEndHour = 0
    Buddy.longTaskAfter = 18
}
// Testing only: pretend it's the middle of the night.
if env["RUBIN_FORCE_NIGHT"] == "1" {
    Buddy.nightWindow = (start: 0, end: 24)
}

if let spec = env["RUBIN_CHATTER"] {
    let parts = spec.split(separator: "-").compactMap { Int($0) }
    if parts.count == 2, parts[0] > 0, parts[1] >= parts[0] {
        Buddy.quietSecondsRange = parts[0]...parts[1]
        Buddy.chatterFromLaunch = true
    }
}

guard acquireInstanceLock(at: stateFile.deletingLastPathComponent()) else {
    FileHandle.standardError.write("buddy: already running\n".data(using: .utf8)!)
    exit(0)
}

let sprites: SpriteSet
do {
    sprites = try SpriteSet(framesDir: framesDir)
} catch {
    FileHandle.standardError.write(
        "buddy: could not load frames from \(framesDir.path): \(error.localizedDescription)\n"
            .data(using: .utf8)!)
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
let buddy = Buddy(sprites: sprites, scale: scale, stateFile: stateFile, linesFile: linesFile)
app.run()
