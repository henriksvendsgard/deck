// Vindusbytter – en enkel Cmd+Tab-vindusbytter for macOS.
// Viser ett element per vindu (app-ikon + vindustittel), sortert etter sist brukt,
// også vinduer på andre Spaces.

import Cocoa
import ApplicationServices
import ServiceManagement

// MARK: - Private API-er (lastes dynamisk, så appen tåler at de mangler)

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

/// Slår macOS' egen Cmd+Tab (1) og Cmd+Shift+Tab (2) av eller på.
func setNativeCommandTab(enabled: Bool) {
    guard let f = setSymbolicHotKey else { return }
    for id: Int32 in [1, 2] { _ = f(id, enabled) }
}

// MARK: - AX-hjelpere

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

/// Antall Spaces et vindu ligger på (0 = vinduet er skjult/ikke i bruk).
func spaceCount(_ wid: CGWindowID) -> Int? {
    guard let conn = mainConnection, let copy = copySpacesForWindows else { return nil }
    let arr = [NSNumber(value: wid)] as CFArray
    guard let res = copy(conn(), 0x7, arr)?.takeRetainedValue() else { return 0 }
    return CFArrayGetCount(res)
}

/// AX gir bare vinduer på gjeldende Space. For å finne resten prøver vi alle
/// element-ID-er for appen (samme teknikk som AltTab bruker).
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
        if err == .cannotComplete { break } // appen svarer ikke – gi opp denne
        if err == .success, let s = v as? String, s == kAXStandardWindowSubrole || s == kAXDialogSubrole {
            found.append(el)
        }
    }
    return found
}

// MARK: - Vinduer

struct WinItem {
    let app: NSRunningApplication
    let element: AXUIElement
    let title: String
    let wid: CGWindowID
    let minimized: Bool
    let icon: NSImage
    var windowless = false      // appen kjører, men har ingen vinduer
    var badge: String? = nil    // varselmerke fra Dock (f.eks. «7»)
}

/// Innstillinger (lagres i UserDefaults, begge er på som standard).
enum Settings {
    static func flag(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    static func set(_ key: String, _ v: Bool) { UserDefaults.standard.set(v, forKey: key) }
    static var showWindowless: Bool {
        get { flag("showWindowlessApps") } set { set("showWindowlessApps", newValue) }
    }
    static var showBadges: Bool {
        get { flag("showBadges") } set { set("showBadges", newValue) }
    }
}

/// Apper, sist aktivert først (for rekkefølgen på apper uten vinduer).
var appMRU: [pid_t] = []

func noteActivated(_ app: NSRunningApplication?) {
    guard let pid = app?.processIdentifier else { return }
    appMRU.removeAll { $0 == pid }
    appMRU.insert(pid, at: 0)
}

/// Leser varselmerkene (røde tall) fra Dock-ikonene, nøklet på app-stien.
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

/// Vinduer på andre Spaces, oppdatert i bakgrunnen (brute force er for tregt å gjøre ved hvert Cmd+Tab).
final class WindowCache {
    private let queue = DispatchQueue(label: "vindusbytter.cache", qos: .utility)
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

/// Sist brukte vinduer, nyeste først.
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

/// Vinduene som er synlige nå er de sist brukte; flytt dem først i MRU-lista.
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

        // Raskt: vinduer på gjeldende Space (og minimerte).
        let axApp = AXUIElementCreateApplication(pid)
        if let wins = axAttr(axApp, kAXWindowsAttribute) as? [AXUIElement] {
            for w in wins where isRealWindow(w) { add(w, checkExists: false) }
        }
        // Fra bakgrunnscachen: vinduer på andre Spaces.
        for w in cache.byPid[pid] ?? [] { add(w, checkExists: true) }

        // Apper som kjører uten vinduer kommer med sist, som i AltTab.
        if Settings.showWindowless && !items.contains(where: { $0.app.processIdentifier == pid }) {
            items.append(WinItem(app: app, element: axApp, title: appName, wid: 0,
                                 minimized: false, icon: icon, windowless: true))
        }
    }

    // Varselmerker fra Dock.
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

    // Vanlige vinduer først, så minimerte, så apper uten vinduer – hver gruppe etter sist brukt.
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

/// Gjør vinduet til hovedvindu (fungerer også når det ligger på et annet Space).
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
        // Bare aktiver appen (som macOS' egen Cmd+Tab), uten å lage nytt vindu.
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

// Mål tatt fra macOS 26 sin egen Cmd+Tab.
enum Layout {
    static let icon: CGFloat = 128         // tegneflate for ikonet (inkl. ikonets innebygde marg)
    static let iconInset: CGFloat = 13     // macOS-ikoner har ~10 % luft rundt selve motivet
    static let itemW: CGFloat = 134        // én celle
    static let iconTop: CGFloat = 0
    static let labelGap: CGFloat = 12      // fra ikonmotivet ned til tittelen
    static let labelH: CGFloat = 15        // tittel under valgt ikon
    static let itemH: CGFloat = iconTop + icon - iconInset + labelGap + labelH
    static let pad: CGFloat = 24           // marg til venstre/høyre
    static let padTop: CGFloat = 28        // gir ~41 pt luft over ikonmotivet
    static let padBottom: CGFloat = 14
    static let corner: CGFloat = 64        // panelets hjørneradius
    static let highlightPad: CGFloat = 8  // markeringen går så langt utenfor ikonmotivet
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

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func rect(for i: Int) -> NSRect {
        let r = i / cols, c = i % cols
        // Siste rad kan ha færre ikoner – sentrer dem.
        let inRow = min(cols, items.count - r * cols)
        let offset = CGFloat(cols - inRow) * Layout.itemW / 2
        return NSRect(x: Layout.pad + offset + CGFloat(c) * Layout.itemW,
                      y: Layout.padTop + CGFloat(r) * Layout.itemH,
                      width: Layout.itemW, height: Layout.itemH)
    }

    func index(at p: NSPoint) -> Int? {
        items.indices.first { rect(for: $0).contains(p) }
    }

    func iconRect(for i: Int) -> NSRect {
        let r = rect(for: i)
        return NSRect(x: r.midX - Layout.icon / 2, y: r.minY + Layout.iconTop,
                      width: Layout.icon, height: Layout.icon)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Som macOS' egen Cmd+Tab: bare ikoner, avrundet markering rundt valgt,
        // og tittelen vises kun under det valgte.

        // Lys glasskant: sterkest øverst, svakere nederst.
        let rim = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                               xRadius: Layout.corner - 0.5, yRadius: Layout.corner - 0.5)
        if let g = NSGradient(colors: [NSColor.white.withAlphaComponent(0.55),
                                       NSColor.white.withAlphaComponent(0.12),
                                       NSColor.white.withAlphaComponent(0.30)]),
           let ctx = NSGraphicsContext.current?.cgContext {
            // Tegn kanten som gradient ved å klippe til selve streken (flippet view: 90° = ovenfra og ned).
            ctx.saveGState()
            ctx.addPath(rim.cgPath)
            ctx.setLineWidth(1.2)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            g.draw(in: bounds, angle: 90)
            ctx.restoreGState()
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

            // Prikk under ikonet på apper som kjører uten vinduer (som i Dock).
            if it.windowless {
                let y = visible.maxY + 3
                NSColor.labelColor.withAlphaComponent(0.75).setFill()
                NSBezierPath(ovalIn: NSRect(x: visible.midX - 2.5, y: y, width: 5, height: 5)).fill()
            }

            // Rødt varselmerke øverst til høyre, som i macOS.
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
        // Teksten holder seg innenfor bredden på markeringen og kuttes med «…».
        let maxW = Layout.icon - 2 * (Layout.iconInset - Layout.highlightPad)
        let textW = min(title.size(withAttributes: attrs).width + 2, maxW)
        let x = ir.midX - textW / 2
        title.draw(with: NSRect(x: x, y: ir.maxY - Layout.iconInset + Layout.labelGap,
                                width: textW, height: Layout.labelH),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    func drawBadge(_ text: String, iconRect r: NSRect) {
        // Mål fra macOS 26: ~46 pt rund prikk, sentrert 13 pt inn og 12 pt ned fra hjørnet.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 25, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let str = text as NSString
        let ts = str.size(withAttributes: attrs)
        let h: CGFloat = 46
        let w = max(h, ts.width + 22)
        let center = NSPoint(x: r.maxX - 13, y: r.minY + 12)
        // Brede merker (f.eks. «128») vokser mot venstre fra høyrekanten.
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

// MARK: - Bytteren

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
            // Liquid Glass, som systemets egen Cmd+Tab i macOS 26.
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.tintColor = NSColor.white.withAlphaComponent(0.10) // litt lysere, som systemets
            glass.cornerRadius = Layout.corner
            glass.contentView = grid
            panel.contentView = glass
            panel.hasShadow = false // glasset tegner sin egen kant og skygge
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

    /// Returnerer true hvis hendelsen skal svelges.
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
            return true // svelg alle taster mens bytteren er åpen
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
        cache.refresh() // hold cachen fersk til neste gang
        guard !items.isEmpty else { return }
        active = true
        selected = items.count > 1 ? (backwards ? items.count - 1 : 1) : 0
        let work = DispatchWorkItem { [weak self] in self?.showPanel() }
        pendingShow = work
        // Liten forsinkelse som i macOS: raskt Cmd+Tab bytter uten å vise panelet.
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
        let vf = screen.visibleFrame
        let maxCols = max(1, Int((vf.width * 0.9 - 2 * Layout.pad) / Layout.itemW))
        let cols = min(items.count, maxCols)
        let rows = (items.count + cols - 1) / cols
        let size = NSSize(width: CGFloat(cols) * Layout.itemW + 2 * Layout.pad,
                          height: CGFloat(rows) * Layout.itemH + Layout.padTop + Layout.padBottom)
        let frame = NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                           width: size.width, height: size.height)
        grid.items = items
        grid.cols = cols
        grid.selected = selected
        panel.setFrame(frame, display: false)
        grid.frame = NSRect(origin: .zero, size: size)
        grid.needsDisplay = true
        panel.orderFrontRegardless()
    }

    /// Etter Cmd+Q / Cmd+W: oppdater panelet, eller lukk det hvis lista er tom.
    func itemsChanged() {
        if items.isEmpty { close(); return }
        selected = min(selected, items.count - 1)
        showPanel()
    }

    func closeSelectedWindow() {
        guard items.indices.contains(selected), !items[selected].windowless else { return }
        let it = items[selected]
        if let btn = axAttr(it.element, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
        }
        items.remove(at: selected)
        itemsChanged()
    }

    func quitSelectedApp() {
        guard items.indices.contains(selected) else { return }
        let app = items[selected].app
        app.terminate()
        items.removeAll { $0.app.processIdentifier == app.processIdentifier }
        itemsChanged()
    }

    func close() {
        active = false
        pendingShow?.cancel()
        pendingShow = nil
        panel.orderOut(nil)
    }

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

/// Menylinje-ikon: to stablede vinduer, det fremste fylt. Template-bilde,
/// så macOS farger det hvitt eller mørkt etter menylinja.
func menuBarIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        NSColor.black.set()
        let back = NSBezierPath(roundedRect: NSRect(x: 1.8, y: 2.8, width: 10, height: 8.5),
                                xRadius: 2.2, yRadius: 2.2)
        back.lineWidth = 1.5
        back.stroke()
        let front = NSBezierPath(roundedRect: NSRect(x: 5.2, y: 6.2, width: 11, height: 9.3),
                                 xRadius: 2.4, yRadius: 2.4)
        // Litt luft rundt det fremste vinduet, så kantene ikke flyter sammen.
        NSGraphicsContext.current?.compositingOperation = .clear
        let gap = NSBezierPath(roundedRect: NSRect(x: 4.2, y: 5.2, width: 13, height: 11.3),
                               xRadius: 3.2, yRadius: 3.2)
        gap.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        front.fill()
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "Vindusbytter"
    return img
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let statusLine = NSMenuItem(title: "Venter på tilgang …", action: nil, keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Start ved innlogging", action: #selector(toggleLogin), keyEquivalent: "")
    let windowlessItem = NSMenuItem(title: "Vis apper uten vinduer", action: #selector(toggleWindowless), keyEquivalent: "")
    let badgesItem = NSMenuItem(title: "Vis varselmerker", action: #selector(toggleBadges), keyEquivalent: "")
    var retryTimer: Timer?
    var cacheTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        windowlessItem.target = self
        badgesItem.target = self
        menu.addItem(windowlessItem)
        menu.addItem(badgesItem)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(withTitle: "Åpne Tilgjengelighet-innstillinger …",
                     action: #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Avslutt Vindusbytter",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        setUpLoginItemFirstTime()

        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        tryStart()
    }

    func tryStart() {
        if AXIsProcessTrusted() && switcher.startTap() {
            setNativeCommandTab(enabled: false)
            statusLine.title = "Aktiv – Cmd+Tab bytter vindu"
            retryTimer?.invalidate()
            retryTimer = nil
            startWatching()
        } else if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.tryStart()
            }
        }
    }

    /// Følg med på app- og Space-bytter for MRU-rekkefølgen og vindus-cachen.
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

    // MARK: Start ved innlogging

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
            NSLog("Vindusbytter: innloggingsobjekt feilet: \(error)")
        }
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc func toggleWindowless() { Settings.showWindowless.toggle() }
    @objc func toggleBadges() { Settings.showBadges.toggle() }

    func menuWillOpen(_ menu: NSMenu) {
        windowlessItem.state = Settings.showWindowless ? .on : .off
        badgesItem.state = Settings.showBadges ? .on : .off
        switch SMAppService.mainApp.status {
        case .enabled:
            loginItem.state = .on
            loginItem.title = "Start ved innlogging"
        case .requiresApproval:
            loginItem.state = .mixed
            loginItem.title = "Start ved innlogging (må godkjennes i Innstillinger)"
        default:
            loginItem.state = .off
            loginItem.title = "Start ved innlogging"
        }
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func applicationWillTerminate(_ notification: Notification) {
        setNativeCommandTab(enabled: true)
    }
}

// `Vindusbytter --preview` viser panelet med kjørende apper i 8 sekunder (for å se på utseendet).
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
    if let last = switcher.items.indices.last { switcher.items[last].windowless = true } // vis prikken
    switcher.active = true
    switcher.selected = min(1, max(0, switcher.items.count - 1))
    DispatchQueue.main.async { switcher.showPanel() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
    app.run()
}

// `Vindusbytter --restore` slår på macOS' egen Cmd+Tab igjen og avslutter (nødbrems).
if CommandLine.arguments.contains("--restore") {
    setNativeCommandTab(enabled: true)
    print("macOS' egen Cmd+Tab er slått på igjen.")
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
