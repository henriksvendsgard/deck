// Deck – a Cmd+Tab window switcher for macOS.
// Shows one item per window (app icon + window title), most recently used first,
// including windows on other Spaces.

import Cocoa
import ApplicationServices
import ServiceManagement

// MARK: - Private APIs (loaded dynamically so the app survives if they are missing)

typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
typealias AXCreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
typealias SetSymbolicHotKeyFn = @convention(c) (Int32, Bool) -> Int32
typealias MainConnectionFn = @convention(c) () -> Int32
typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32

let appServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

func load<T>(_ handle: UnsafeMutableRawPointer?, _ names: String..., as: T.Type) -> T? {
    for n in names { if let s = dlsym(handle, n) { return unsafeBitCast(s, to: T.self) } }
    return nil
}

let axGetWindow = load(appServices, "_AXUIElementGetWindow", as: AXGetWindowFn.self)
let axCreateWithRemoteToken = load(appServices, "_AXUIElementCreateWithRemoteToken", as: AXCreateWithRemoteTokenFn.self)
let getProcessForPID = load(appServices, "GetProcessForPID", as: GetProcessForPIDFn.self)
let setSymbolicHotKey = load(skyLight, "SLSSetSymbolicHotKeyEnabled", "CGSSetSymbolicHotKeyEnabled", as: SetSymbolicHotKeyFn.self)
let mainConnection = load(skyLight, "SLSMainConnectionID", "CGSMainConnectionID", as: MainConnectionFn.self)
let copySpacesForWindows = load(skyLight, "SLSCopySpacesForWindows", "CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
let setFrontProcess = load(skyLight, "_SLPSSetFrontProcessWithOptions", as: SetFrontProcessFn.self)
let postEventRecord = load(skyLight, "SLPSPostEventRecordTo", as: PostEventRecordFn.self)

/// Turns the system Cmd+Tab (1) and Cmd+Shift+Tab (2) hotkeys on or off.
func setNativeCommandTab(enabled: Bool) {
    guard let f = setSymbolicHotKey else { return }
    for id: Int32 in [1, 2] { _ = f(id, enabled) }
}

// MARK: - AX helpers

func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func windowID(_ el: AXUIElement) -> CGWindowID {
    var wid: CGWindowID = 0
    if let f = axGetWindow { _ = f(el, &wid) }
    return wid
}

func isRealWindow(_ el: AXUIElement) -> Bool {
    let subrole = axAttr(el, kAXSubroleAttribute) as? String
    return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
}

/// Number of Spaces a window is on (0 = the window is ordered out / unused).
func spaceCount(_ wid: CGWindowID) -> Int? {
    guard let conn = mainConnection, let copy = copySpacesForWindows else { return nil }
    let arr = [NSNumber(value: wid)] as CFArray
    guard let res = copy(conn(), 0x7, arr)?.takeRetainedValue() else { return 0 }
    return CFArrayGetCount(res)
}

/// AX only returns windows on the current Space. To find the rest we try every
/// element ID for the app (the same technique AltTab uses).
func bruteForceWindows(pid: pid_t) -> [AXUIElement] {
    guard let create = axCreateWithRemoteToken else { return [] }
    var token = Data(count: 20)
    token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
    token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
    var found: [AXUIElement] = []
    for id: UInt64 in 0..<1000 {
        token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
        guard let el = create(token as CFData)?.takeRetainedValue() else { continue }
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &v)
        if err == .cannotComplete { break } // app is not responding – give up on it
        if err == .success, let s = v as? String, s == kAXStandardWindowSubrole || s == kAXDialogSubrole {
            found.append(el)
        }
    }
    return found
}

// MARK: - Windows

struct WinItem {
    let app: NSRunningApplication
    let element: AXUIElement
    let title: String
    let wid: CGWindowID
    let minimized: Bool
    let icon: NSImage
    var windowless = false      // the app runs but has no windows
    var badge: String? = nil    // notification badge from the Dock (e.g. "7")
}

/// Settings (stored in UserDefaults). Windowless apps are off and badges on by default.
enum Settings {
    static func flag(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }
    static func set(_ key: String, _ v: Bool) { UserDefaults.standard.set(v, forKey: key) }
    static var showWindowless: Bool {
        get { flag("showWindowlessApps", default: false) } set { set("showWindowlessApps", newValue) }
    }
    static var showBadges: Bool {
        get { flag("showBadges", default: true) } set { set("showBadges", newValue) }
    }
    static var checkForUpdates: Bool {
        get { flag("checkForUpdates", default: true) } set { set("checkForUpdates", newValue) }
    }
}

// MARK: - Update check

/// Asks GitHub for the latest release. Nothing is downloaded or installed automatically:
/// Deck only tells you that a new version exists and how to get it.
enum Updates {
    static let repo = "henriksvendsgard/deck"
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    /// Installed with `brew install --cask`?
    static var viaHomebrew: Bool {
        ["/opt/homebrew/Caskroom/deck", "/usr/local/Caskroom/deck"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    struct Release { let version: String; let notes: String; let url: URL }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func fetchLatest(_ done: @escaping (Release?) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Deck/\(current)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var release: Release?
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String,
               let page = (json["html_url"] as? String).flatMap(URL.init(string:)) {
                // The release notes end where the generic install instructions begin.
                let body = (json["body"] as? String ?? "")
                    .components(separatedBy: "### Install").first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                release = Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                                  notes: body, url: page)
            }
            DispatchQueue.main.async { done(release) }
        }.resume()
    }
}

/// Apps, most recently activated first (orders the windowless apps).
var appMRU: [pid_t] = []

func noteActivated(_ app: NSRunningApplication?) {
    guard let pid = app?.processIdentifier else { return }
    appMRU.removeAll { $0 == pid }
    appMRU.insert(pid, at: 0)
}

/// Reads the notification badges (red numbers) from the Dock icons, keyed by app path.
func dockBadges() -> [String: String] {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    else { return [:] }
    let axDock = AXUIElementCreateApplication(dock.processIdentifier)
    guard let children = axAttr(axDock, kAXChildrenAttribute) as? [AXUIElement] else { return [:] }
    var result: [String: String] = [:]
    for list in children where (axAttr(list, kAXRoleAttribute) as? String) == kAXListRole {
        for item in (axAttr(list, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            guard let label = axAttr(item, "AXStatusLabel") as? String, !label.isEmpty,
                  let url = axAttr(item, kAXURLAttribute) as? URL else { continue }
            result[normalizedPath(url)] = label
        }
    }
    return result
}

func normalizedPath(_ url: URL) -> String {
    var p = url.standardizedFileURL.resolvingSymlinksInPath().path
    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
    return p
}

/// Windows on other Spaces, refreshed in the background (brute force is too slow for every Cmd+Tab).
final class WindowCache {
    private let queue = DispatchQueue(label: "deck.cache", qos: .utility)
    private var running = false
    private var again = false
    private(set) var byPid: [pid_t: [AXUIElement]] = [:]

    func refresh() {
        if running { again = true; return }
        running = true
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .map(\.processIdentifier)
        queue.async {
            var result: [pid_t: [AXUIElement]] = [:]
            for pid in pids {
                result[pid] = bruteForceWindows(pid: pid).filter { el in
                    let wid = windowID(el)
                    guard wid != 0 else { return false }
                    if (axAttr(el, kAXMinimizedAttribute) as? Bool) == true { return true }
                    return (spaceCount(wid) ?? 1) > 0
                }
            }
            DispatchQueue.main.async {
                self.byPid = result
                self.running = false
                if self.again { self.again = false; self.refresh() }
            }
        }
    }
}

let cache = WindowCache()

/// Most recently used windows, newest first.
var mru: [CGWindowID] = []

func onScreenZOrder() -> [CGWindowID] {
    guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
    return info.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0, let n = w[kCGWindowNumber as String] as? Int
        else { return nil }
        return CGWindowID(n)
    }
}

/// The windows visible right now are the most recent ones; move them to the front of the MRU list.
func noteVisibleWindows() {
    let visible = onScreenZOrder()
    let set = Set(visible)
    mru.removeAll { set.contains($0) }
    mru.insert(contentsOf: visible, at: 0)
    if mru.count > 500 { mru.removeLast(mru.count - 500) }
}

func existingWindowIDs() -> Set<CGWindowID> {
    guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
    return Set(info.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0, let n = w[kCGWindowNumber as String] as? Int
        else { return nil }
        return CGWindowID(n)
    })
}

func collectWindows() -> [WinItem] {
    noteVisibleWindows()
    let existing = existingWindowIDs()
    let myPid = getpid()
    var items: [WinItem] = []
    var seen = Set<CGWindowID>()

    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular && app.processIdentifier != myPid {
        let pid = app.processIdentifier
        let appName = app.localizedName ?? ""
        let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()

        func add(_ w: AXUIElement, checkExists: Bool) {
            let wid = windowID(w)
            if wid != 0 {
                if seen.contains(wid) { return }
                if checkExists && !existing.contains(wid) { return }
                seen.insert(wid)
            } else if checkExists { return }
            let rawTitle = (axAttr(w, kAXTitleAttribute) as? String) ?? ""
            let minimized = (axAttr(w, kAXMinimizedAttribute) as? Bool) ?? false
            items.append(WinItem(app: app, element: w, title: rawTitle.isEmpty ? appName : rawTitle,
                                 wid: wid, minimized: minimized, icon: icon))
        }

        // Fast path: windows on the current Space (and minimized ones).
        let axApp = AXUIElementCreateApplication(pid)
        if let wins = axAttr(axApp, kAXWindowsAttribute) as? [AXUIElement] {
            for w in wins where isRealWindow(w) { add(w, checkExists: false) }
        }
        // From the background cache: windows on other Spaces.
        for w in cache.byPid[pid] ?? [] { add(w, checkExists: true) }

        // Apps running without windows go last, like in AltTab.
        if Settings.showWindowless && !items.contains(where: { $0.app.processIdentifier == pid }) {
            items.append(WinItem(app: app, element: axApp, title: appName, wid: 0,
                                 minimized: false, icon: icon, windowless: true))
        }
    }

    // Notification badges from the Dock.
    let badges = Settings.showBadges ? dockBadges() : [:]
    if !badges.isEmpty {
        for i in items.indices {
            if let url = items[i].app.bundleURL { items[i].badge = badges[normalizedPath(url)] }
        }
    }

    var rank: [CGWindowID: Int] = [:]
    for (i, wid) in mru.enumerated() where rank[wid] == nil { rank[wid] = i }
    var appRank: [pid_t: Int] = [:]
    for (i, pid) in appMRU.enumerated() where appRank[pid] == nil { appRank[pid] = i }

    // Regular windows first, then minimized, then windowless apps – each group by recency.
    func group(_ it: WinItem) -> Int { it.windowless ? 2 : (it.minimized ? 1 : 0) }
    return items.enumerated().sorted { a, b in
        let ga = group(a.element), gb = group(b.element)
        if ga != gb { return ga < gb }
        if ga == 2 {
            let ra = appRank[a.element.app.processIdentifier] ?? Int.max
            let rb = appRank[b.element.app.processIdentifier] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }
        let ra = rank[a.element.wid] ?? Int.max, rb = rank[b.element.wid] ?? Int.max
        return ra != rb ? ra < rb : a.offset < b.offset
    }.map { $0.element }
}

/// Makes the window key (also works when it is on another Space).
func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID) {
    guard let post = postEventRecord else { return }
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    withUnsafeBytes(of: wid) { for i in 0..<4 { bytes[0x3c + i] = $0[i] } }
    for i in 0x20..<0x30 { bytes[i] = 0xff }
    bytes[0x08] = 0x01
    _ = post(&psn, &bytes)
    bytes[0x08] = 0x02
    _ = post(&psn, &bytes)
}

func focus(_ item: WinItem) {
    if item.app.isHidden { item.app.unhide() }
    if item.windowless {
        // Just activate the app (like the system Cmd+Tab) without opening a new window.
        var psn = ProcessSerialNumber()
        if let getPSN = getProcessForPID, let setFront = setFrontProcess,
           getPSN(item.app.processIdentifier, &psn) == noErr {
            _ = setFront(&psn, 0, 0x400) // kCPSNoWindows
        }
        if #available(macOS 14, *) { item.app.activate() } else { item.app.activate(options: []) }
        noteActivated(item.app)
        return
    }
    if item.minimized {
        AXUIElementSetAttributeValue(item.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    var psn = ProcessSerialNumber()
    if item.wid != 0, let getPSN = getProcessForPID, let setFront = setFrontProcess,
       getPSN(item.app.processIdentifier, &psn) == noErr {
        _ = setFront(&psn, item.wid, 0x200) // kCPSUserGenerated
        makeKeyWindow(&psn, item.wid)
        AXUIElementPerformAction(item.element, kAXRaiseAction as CFString)
    } else {
        let axApp = AXUIElementCreateApplication(item.app.processIdentifier)
        AXUIElementPerformAction(item.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(item.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if #available(macOS 14, *) { item.app.activate() } else { item.app.activate(options: []) }
    }
    if item.wid != 0 {
        mru.removeAll { $0 == item.wid }
        mru.insert(item.wid, at: 0)
    }
}

// MARK: - UI

// Measurements taken from the macOS 26 Cmd+Tab switcher.
enum Layout {
    static let icon: CGFloat = 128         // icon drawing size (includes the icon's built-in margin)
    static let iconInset: CGFloat = 13     // macOS icons have ~10% padding around the artwork
    static let itemW: CGFloat = 134        // one cell
    static let iconTop: CGFloat = 0
    static let labelGap: CGFloat = 12      // from the icon artwork down to the title
    static let labelH: CGFloat = 15        // title under the selected icon
    static let itemH: CGFloat = iconTop + icon - iconInset + labelGap + labelH
    static let pad: CGFloat = 24           // left/right padding
    static let padTop: CGFloat = 28        // ~41 pt above the icon artwork
    static let padBottom: CGFloat = 14
    static let corner: CGFloat = 64        // panel corner radius
    static let highlightPad: CGFloat = 8  // how far the highlight extends past the artwork
    static let highlightCorner: CGFloat = 32
}

final class SwitcherPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class GridView: NSView {
    var items: [WinItem] = []
    var selected = 0
    var cols = 1
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    /// While a Cmd+Q / Cmd+W animation runs: where each item is drawn right now,
    /// and the removed items, which shrink and fade out (progress 0 → 1).
    var animatedRects: [NSRect]?
    var ghosts: [(item: WinItem, cell: NSRect, progress: CGFloat)] = []

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func rect(for i: Int) -> NSRect {
        if let a = animatedRects, a.indices.contains(i) { return a[i] }
        return layoutRect(for: i)
    }

    /// The resting position of item i in the grid.
    func layoutRect(for i: Int) -> NSRect {
        let r = i / cols, c = i % cols
        // The last row may have fewer icons – center them.
        let inRow = min(cols, items.count - r * cols)
        let offset = CGFloat(cols - inRow) * Layout.itemW / 2
        return NSRect(x: Layout.pad + offset + CGFloat(c) * Layout.itemW,
                      y: Layout.padTop + CGFloat(r) * Layout.itemH,
                      width: Layout.itemW, height: Layout.itemH)
    }

    func index(at p: NSPoint) -> Int? {
        items.indices.first { rect(for: $0).contains(p) }
    }

    func iconRect(for i: Int) -> NSRect { iconRect(inCell: rect(for: i)) }

    func iconRect(inCell r: NSRect) -> NSRect {
        return NSRect(x: r.midX - Layout.icon / 2, y: r.minY + Layout.iconTop,
                      width: Layout.icon, height: Layout.icon)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Like the system Cmd+Tab: icons only, a rounded highlight behind the selected one,
        // and the title only under the selected item.

        // Bright glass rim: strongest at the top, fainter at the bottom.
        let rim = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                               xRadius: Layout.corner - 0.5, yRadius: Layout.corner - 0.5)
        if let g = NSGradient(colors: [NSColor.white.withAlphaComponent(0.55),
                                       NSColor.white.withAlphaComponent(0.12),
                                       NSColor.white.withAlphaComponent(0.30)]),
           let ctx = NSGraphicsContext.current?.cgContext {
            // Draw the rim as a gradient by clipping to the stroke (flipped view: 90° = top to bottom).
            ctx.saveGState()
            ctx.addPath(rim.cgPath)
            ctx.setLineWidth(1.2)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            g.draw(in: bounds, angle: 90)
            ctx.restoreGState()
        }

        for g in ghosts {
            let ir = iconRect(inCell: g.cell)
            let s = 1 - 0.35 * g.progress
            let r = NSRect(x: ir.midX - ir.width * s / 2, y: ir.midY - ir.height * s / 2,
                           width: ir.width * s, height: ir.height * s)
            g.item.icon.draw(in: r, from: .zero, operation: .sourceOver,
                             fraction: (1 - g.progress) * (g.item.minimized ? 0.45 : 1),
                             respectFlipped: true, hints: nil)
        }

        for (i, it) in items.enumerated() {
            let ir = iconRect(for: i)
            if i == selected {
                let hr = ir.insetBy(dx: Layout.iconInset - Layout.highlightPad,
                                    dy: Layout.iconInset - Layout.highlightPad)
                let path = NSBezierPath(roundedRect: hr, xRadius: Layout.highlightCorner,
                                        yRadius: Layout.highlightCorner)
                NSColor.white.withAlphaComponent(0.26).setFill()
                path.fill()
                NSColor.white.withAlphaComponent(0.35).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            it.icon.draw(in: ir, from: .zero, operation: .sourceOver,
                         fraction: it.minimized ? 0.45 : 1, respectFlipped: true, hints: nil)
            let visible = ir.insetBy(dx: Layout.iconInset, dy: Layout.iconInset)

            // Dot under the icon for apps running without windows (like the Dock).
            if it.windowless {
                let y = visible.maxY + 3
                NSColor.labelColor.withAlphaComponent(0.75).setFill()
                NSBezierPath(roundedRect: NSRect(x: visible.midX - 4, y: y, width: 8, height: 4),
                             xRadius: 2, yRadius: 2).fill()
            }

            // Red notification badge in the top right corner, like macOS.
            if let badge = it.badge { drawBadge(badge, iconRect: visible) }
        }

        guard items.indices.contains(selected) else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]
        let title = items[selected].title as NSString
        let ir = iconRect(for: selected)
        // The title stays within the highlight width and is truncated with "…".
        let maxW = Layout.icon - 2 * (Layout.iconInset - Layout.highlightPad)
        let textW = min(title.size(withAttributes: attrs).width + 2, maxW)
        let x = ir.midX - textW / 2
        title.draw(with: NSRect(x: x, y: ir.maxY - Layout.iconInset + Layout.labelGap,
                                width: textW, height: Layout.labelH),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    func drawBadge(_ text: String, iconRect r: NSRect) {
        // Measured from macOS 26: ~46 pt circle, centered 13 pt in and 12 pt down from the corner.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 25, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let str = text as NSString
        let ts = str.size(withAttributes: attrs)
        let h: CGFloat = 46
        let w = max(h, ts.width + 22)
        let center = NSPoint(x: r.maxX - 13, y: r.minY + 12)
        // Wide badges (e.g. "128") grow leftwards from the right edge.
        let rect = NSRect(x: center.x + h / 2 - w, y: center.y - h / 2, width: w, height: h)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
        str.draw(at: NSPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2), withAttributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)), i != selected { onHover?(i) }
    }

    override func mouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onClick?(i) }
    }
}

func roundedMask(_ r: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    img.resizingMode = .stretch
    return img
}

// MARK: - Switcher

final class Switcher {
    var tap: CFMachPort?
    var items: [WinItem] = []
    var selected = 0
    var active = false
    var swallowTabUp = false
    var pendingShow: DispatchWorkItem?

    let panel = SwitcherPanel()
    let grid = GridView()

    init() {
        grid.autoresizingMask = [.width, .height]
        if #available(macOS 26, *) {
            // Liquid Glass, like the system Cmd+Tab on macOS 26.
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.tintColor = NSColor.white.withAlphaComponent(0.10) // slightly lighter, like the system's
            glass.cornerRadius = Layout.corner
            glass.contentView = grid
            panel.contentView = glass
            panel.hasShadow = false // the glass draws its own edge and shadow
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.maskImage = roundedMask(Layout.corner)
            blur.addSubview(grid)
            panel.contentView = blur
        }
        grid.onHover = { [weak self] i in self?.select(i) }
        grid.onClick = { [weak self] i in self?.select(i); self?.commit() }
    }

    func startTap() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                        callback: tapCallback, userInfo: nil) else { return false }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        return true
    }

    /// Returns true if the event should be swallowed.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        let flags = event.flags
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let cmd = flags.contains(.maskCommand)

        switch type {
        case .keyDown:
            if key == 48 && cmd { // Tab
                swallowTabUp = true
                let back = flags.contains(.maskShift)
                if active { step(back ? -1 : 1) } else { begin(backwards: back) }
                return true
            }
            guard active else { return false }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            switch key {
            case 53: cancel()                 // Esc
            case 36, 76: commit()             // Return / Enter
            case 123: step(-1)                // ←
            case 124: step(1)                 // →
            case 126: step(-grid.cols)        // ↑
            case 125: step(grid.cols)         // ↓
            case 12 where !isRepeat: quitSelectedApp()   // Q
            case 13 where !isRepeat: closeSelectedWindow() // W
            default: break
            }
            return true // swallow all keys while the switcher is open
        case .keyUp:
            if key == 48 && swallowTabUp { swallowTabUp = false; return true }
            return active
        case .flagsChanged:
            if active && !cmd { commit() }
            return false
        default:
            return false
        }
    }

    func begin(backwards: Bool) {
        items = collectWindows()
        cache.refresh() // keep the cache fresh for next time
        guard !items.isEmpty else { return }
        active = true
        selected = items.count > 1 ? (backwards ? items.count - 1 : 1) : 0
        let work = DispatchWorkItem { [weak self] in self?.showPanel() }
        pendingShow = work
        // Short delay like macOS: a quick Cmd+Tab switches without showing the panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func step(_ d: Int) {
        guard !items.isEmpty else { return }
        let n = items.count
        select(((selected + d) % n + n) % n)
    }

    func select(_ i: Int) {
        selected = i
        grid.selected = i
        grid.needsDisplay = true
    }

    func showPanel() {
        guard active, !items.isEmpty else { return }
        pendingShow?.cancel()
        pendingShow = nil
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        finishRemoval()
        let (frame, cols) = panelLayout(count: items.count, on: screen)
        grid.items = items
        grid.cols = cols
        grid.selected = selected
        panel.setFrame(frame, display: false)
        grid.frame = NSRect(origin: .zero, size: frame.size)
        grid.needsDisplay = true
        fadeGeneration += 1 // cancel any fade-out in progress
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Panel frame and column count for a number of items, centered on the screen.
    func panelLayout(count: Int, on screen: NSScreen) -> (frame: NSRect, cols: Int) {
        let vf = screen.visibleFrame
        let maxCols = max(1, Int((vf.width * 0.9 - 2 * Layout.pad) / Layout.itemW))
        let cols = max(1, min(count, maxCols))
        let rows = (count + cols - 1) / cols
        let size = NSSize(width: CGFloat(cols) * Layout.itemW + 2 * Layout.pad,
                          height: CGFloat(rows) * Layout.itemH + Layout.padTop + Layout.padBottom)
        let frame = NSRect(x: (vf.midX - size.width / 2).rounded(), y: (vf.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        return (frame, cols)
    }

    var removalTimer: Timer?
    var removalTarget: NSRect?

    /// After Cmd+Q / Cmd+W: the removed icons shrink and fade, then the rest slide
    /// into place while the panel shrinks to fit. Closes the panel if nothing is left.
    func remove(where gone: (WinItem) -> Bool) {
        finishRemoval()
        let old = items
        let keep = old.indices.filter { !gone(old[$0]) }
        guard keep.count < old.count else { return }
        items = keep.map { old[$0] }
        if items.isEmpty { close(); return }
        selected = min(selected, items.count - 1)
        guard panel.isVisible, let screen = panel.screen ?? NSScreen.main else { showPanel(); return }

        // Work in screen coordinates so items keep their place while the panel moves.
        func toScreen(_ r: NSRect, _ f: NSRect) -> NSRect {
            NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
        }
        func toLocal(_ r: NSRect, _ f: NSRect) -> NSRect {
            NSRect(x: r.minX - f.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
        }
        func lerp(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
            NSRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                   width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
        }

        let from = panel.frame
        let oldCells = old.indices.map { toScreen(grid.rect(for: $0), from) }
        let (to, cols) = panelLayout(count: items.count, on: screen)
        grid.items = items
        grid.cols = cols
        grid.selected = selected
        let startCells = keep.map { oldCells[$0] }
        let endCells = items.indices.map { toScreen(grid.layoutRect(for: $0), to) }
        let ghostCells = old.indices.filter { !keep.contains($0) }.map { (old[$0], oldCells[$0]) }

        let fadeDur = 0.14, moveDelay = 0.08, moveDur = 0.24
        let start = CACurrentMediaTime()
        removalTarget = to
        let tick = { [weak self] in
            guard let self else { return }
            let t = CACurrentMediaTime() - start
            let fade = CGFloat(min(1, t / fadeDur))
            let m = CGFloat(max(0, min(1, (t - moveDelay) / moveDur)))
            let move = m < 0.5 ? 4 * m * m * m : 1 - pow(-2 * m + 2, 3) / 2 // ease in-out
            var f = lerp(from, to, move)
            f = NSRect(x: f.minX.rounded(), y: f.minY.rounded(), width: f.width.rounded(), height: f.height.rounded())
            if self.panel.frame != f { self.panel.setFrame(f, display: true) }
            self.grid.frame = NSRect(origin: .zero, size: f.size)
            self.grid.ghosts = ghostCells.map { ($0.0, toLocal($0.1, f), 1 - pow(1 - fade, 2)) }
            self.grid.animatedRects = zip(startCells, endCells).map { toLocal(lerp($0, $1, move), f) }
            self.grid.needsDisplay = true
            if t >= moveDelay + moveDur { self.finishRemoval() }
        }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in tick() }
        RunLoop.main.add(timer, forMode: .common)
        removalTimer = timer
        tick()
    }

    /// Ends a running Cmd+Q / Cmd+W animation at its final state.
    func finishRemoval() {
        guard let timer = removalTimer else { return }
        timer.invalidate()
        removalTimer = nil
        grid.ghosts = []
        grid.animatedRects = nil
        if let to = removalTarget {
            panel.setFrame(to, display: true)
            grid.frame = NSRect(origin: .zero, size: to.size)
        }
        removalTarget = nil
        grid.needsDisplay = true
    }

    func closeSelectedWindow() {
        guard items.indices.contains(selected), !items[selected].windowless else { return }
        let it = items[selected]
        if let btn = axAttr(it.element, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
        }
        remove { CFEqual($0.element, it.element) }
    }

    func quitSelectedApp() {
        guard items.indices.contains(selected) else { return }
        let app = items[selected].app
        app.terminate()
        remove { $0.app.processIdentifier == app.processIdentifier }
    }

    func close() {
        finishRemoval()
        active = false
        pendingShow?.cancel()
        pendingShow = nil
        guard panel.isVisible else { return }
        // Short, subtle fade-out like macOS. The generation counter stops an old fade
        // from hiding the panel if Cmd+Tab is pressed again while it runs.
        fadeGeneration += 1
        let gen = fadeGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, gen == self.fadeGeneration, !self.active else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }

    var fadeGeneration = 0

    func commit() {
        guard active, items.indices.contains(selected) else { close(); return }
        let item = items[selected]
        close()
        DispatchQueue.main.async { focus(item) }
    }

    func cancel() { close() }
}

let switcher = Switcher()

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = switcher.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    return switcher.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

// MARK: - App

/// Menu bar icon: two stacked windows, the front one filled. A template image,
/// so macOS tints it white or dark to match the menu bar.
func menuBarIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        NSColor.black.set()
        let back = NSBezierPath(roundedRect: NSRect(x: 1.8, y: 2.8, width: 10, height: 8.5),
                                xRadius: 2.2, yRadius: 2.2)
        back.lineWidth = 1.5
        back.stroke()
        let front = NSBezierPath(roundedRect: NSRect(x: 5.2, y: 6.2, width: 11, height: 9.3),
                                 xRadius: 2.4, yRadius: 2.4)
        // A small gap around the front window so the outlines don't merge.
        NSGraphicsContext.current?.compositingOperation = .clear
        let gap = NSBezierPath(roundedRect: NSRect(x: 4.2, y: 5.2, width: 13, height: 11.3),
                               xRadius: 3.2, yRadius: 3.2)
        gap.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        front.fill()
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "Deck"
    return img
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let statusLine = NSMenuItem(title: "Waiting for Accessibility access…", action: nil, keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    let windowlessItem = NSMenuItem(title: "Show Apps Without Windows", action: #selector(toggleWindowless), keyEquivalent: "")
    let badgesItem = NSMenuItem(title: "Show Notification Badges", action: #selector(toggleBadges), keyEquivalent: "")
    let updateAvailableItem = NSMenuItem(title: "", action: #selector(showUpdate), keyEquivalent: "")
    let autoUpdateItem = NSMenuItem(title: "Check for Updates Automatically", action: #selector(toggleAutoUpdate), keyEquivalent: "")
    var available: Updates.Release?
    var updateTimer: Timer?
    var retryTimer: Timer?
    var cacheTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        updateAvailableItem.target = self
        updateAvailableItem.isHidden = true
        menu.addItem(updateAvailableItem)
        menu.addItem(.separator())
        windowlessItem.target = self
        badgesItem.target = self
        menu.addItem(windowlessItem)
        menu.addItem(badgesItem)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(withTitle: "Open Accessibility Settings…",
                     action: #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(.separator())
        autoUpdateItem.target = self
        menu.addItem(autoUpdateItem)
        menu.addItem(withTitle: "Check for Updates…",
                     action: #selector(checkForUpdatesNow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Deck",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        setUpLoginItemFirstTime()

        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        tryStart()

        // Check shortly after launch, then twice a day.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkInBackground() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { [weak self] _ in
            self?.checkInBackground()
        }
    }

    // MARK: Updates

    func checkInBackground() {
        guard Settings.checkForUpdates else { return }
        Updates.fetchLatest { [weak self] r in
            guard let self, let r, Updates.isNewer(r.version, than: Updates.current) else { return }
            self.setAvailable(r)
            // Show the dialog once per version; after that it waits in the menu.
            let key = "notifiedVersion"
            guard UserDefaults.standard.string(forKey: key) != r.version else { return }
            UserDefaults.standard.set(r.version, forKey: key)
            self.presentUpdate(r)
        }
    }

    @objc func checkForUpdatesNow() {
        Updates.fetchLatest { [weak self] r in
            guard let self else { return }
            guard let r else {
                self.alert("Couldn't check for updates", "Check your internet connection and try again.")
                return
            }
            if Updates.isNewer(r.version, than: Updates.current) {
                self.setAvailable(r)
                self.presentUpdate(r)
            } else {
                self.alert("Deck is up to date", "Version \(Updates.current) is the newest version.")
            }
        }
    }

    func setAvailable(_ r: Updates.Release) {
        available = r
        updateAvailableItem.title = "Update Available: Deck \(r.version)…"
        updateAvailableItem.isHidden = false
    }

    @objc func showUpdate() { if let r = available { presentUpdate(r) } }

    func presentUpdate(_ r: Updates.Release) {
        let a = NSAlert()
        a.messageText = "Deck \(r.version) is available"
        var info = "You have version \(Updates.current)."
        if !r.notes.isEmpty { info += "\n\n" + String(r.notes.prefix(600)) }
        let command = "brew upgrade --cask deck"
        if Updates.viaHomebrew {
            info += "\n\nUpdate with Homebrew:\n\(command)"
            a.addButton(withTitle: "Copy Command")
            a.addButton(withTitle: "Release Notes")
        } else {
            a.addButton(withTitle: "Download")
        }
        a.addButton(withTitle: "Later")
        info += "\n\nAfter updating, grant Accessibility access to the new Deck again."
        a.informativeText = info
        if let icon = NSApp.applicationIconImage { a.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        let res = a.runModal()
        if Updates.viaHomebrew {
            if res == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } else if res == .alertSecondButtonReturn {
                NSWorkspace.shared.open(r.url)
            }
        } else if res == .alertFirstButtonReturn {
            NSWorkspace.shared.open(r.url)
        }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc func toggleAutoUpdate() {
        Settings.checkForUpdates.toggle()
        if Settings.checkForUpdates { checkInBackground() }
    }

    func tryStart() {
        if AXIsProcessTrusted() && switcher.startTap() {
            setNativeCommandTab(enabled: false)
            statusLine.title = "Active – Cmd+Tab switches windows"
            retryTimer?.invalidate()
            retryTimer = nil
            startWatching()
        } else if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.tryStart()
            }
        }
    }

    /// Watch app and Space changes for the MRU order and the window cache.
    func startWatching() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            noteActivated(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { noteVisibleWindows() }
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { cache.refresh() }
            }
        }
        cacheTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in cache.refresh() }
        noteVisibleWindows()
        cache.refresh()
    }

    // MARK: Open at login

    func setUpLoginItemFirstTime() {
        let key = "loginItemSetUp"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("Deck: login item failed: \(error)")
        }
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc func toggleWindowless() { Settings.showWindowless.toggle() }
    @objc func toggleBadges() { Settings.showBadges.toggle() }

    func menuWillOpen(_ menu: NSMenu) {
        windowlessItem.state = Settings.showWindowless ? .on : .off
        badgesItem.state = Settings.showBadges ? .on : .off
        autoUpdateItem.state = Settings.checkForUpdates ? .on : .off
        switch SMAppService.mainApp.status {
        case .enabled:
            loginItem.state = .on
            loginItem.title = "Open at Login"
        case .requiresApproval:
            loginItem.state = .mixed
            loginItem.title = "Open at Login (approve in System Settings)"
        default:
            loginItem.state = .off
            loginItem.title = "Open at Login"
        }
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func applicationWillTerminate(_ notification: Notification) {
        setNativeCommandTab(enabled: true)
    }
}

// `Deck --preview` shows the panel with running apps for 8 seconds (to check the look).
if CommandLine.arguments.contains("--preview") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.prefix(8)
    switcher.items = apps.map {
        WinItem(app: $0, element: AXUIElementCreateApplication($0.processIdentifier),
                title: $0.localizedName ?? "", wid: 0, minimized: false, icon: $0.icon ?? NSImage())
    }
    let badges = dockBadges()
    for i in switcher.items.indices {
        if let url = switcher.items[i].app.bundleURL { switcher.items[i].badge = badges[normalizedPath(url)] }
    }
    if let last = switcher.items.indices.last { switcher.items[last].windowless = true } // show the dot
    switcher.active = true
    switcher.selected = min(1, max(0, switcher.items.count - 1))
    DispatchQueue.main.async { switcher.showPanel() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
    app.run()
}

// `Deck --check-updates` prints the latest release (to test the update check).
if CommandLine.arguments.contains("--check-updates") {
    Updates.fetchLatest { r in
        if let r {
            print("Installed \(Updates.current), latest \(r.version), newer: \(Updates.isNewer(r.version, than: Updates.current))")
            print("Homebrew: \(Updates.viaHomebrew), page: \(r.url)")
        } else {
            print("Could not reach GitHub.")
        }
        exit(0)
    }
    RunLoop.main.run()
}

// `Deck --restore` turns the system Cmd+Tab back on and exits (emergency brake).
if CommandLine.arguments.contains("--restore") {
    setNativeCommandTab(enabled: true)
    print("The system Cmd+Tab is turned back on.")
    exit(0)
}

atexit { setNativeCommandTab(enabled: true) }

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { NSApp.terminate(nil) }
    s.resume()
    signalSources.append(s)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
