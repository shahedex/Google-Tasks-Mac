import AppKit
import SwiftUI

/// Renders the README screenshots from the real views with demo data:
///   "Google Tasks.app/Contents/MacOS/GoogleTasks" --screenshots docs/screenshots
@MainActor
enum ScreenshotRenderer {
    static func run(outputDirectory: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let main = demoModel()
            window(MainView().environment(main), size: CGSize(width: 1180, height: 720), title: "Google Tasks",
                   appearance: appearance, to: dir.appendingPathComponent("main-\(suffix).png"))

            let menu = demoModel()
            menuBar(menu, appearance: appearance, to: dir.appendingPathComponent("menubar-\(suffix).png"))

            let offline = demoModel(pendingChanges: 3, offline: true)
            offline.selectedListID = "groceries"
            offline.selectedTaskID = nil
            window(MainView().environment(offline), size: CGSize(width: 1180, height: 720), title: "Google Tasks",
                   appearance: appearance, to: dir.appendingPathComponent("offline-\(suffix).png"))

            let setup = AppModel(demo: true)
            window(RootView().environment(setup), size: CGSize(width: 900, height: 700), title: "Google Tasks",
                   appearance: appearance, to: dir.appendingPathComponent("setup-\(suffix).png"))
        }
        print("Screenshots written to \(dir.path)")
        exit(0)
    }

    // MARK: Rendering

    private static func window<V: View>(_ view: V, size: CGSize, title: String, appearance: NSAppearance.Name, to url: URL) {
        let window = ActiveWindow(
            contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.title = title
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.setContentSize(size)
        window.orderFrontRegardless()
        settle()
        // Ask the window server for the composited window (vibrancy, title bar and toolbar included).
        if let image = windowImage(window) {
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = window.frame.size
            compose(rep, size: window.frame.size, rounded: true, appearance: appearance, to: url)
        } else {
            save(hosting.superview ?? hosting, rounded: true, appearance: appearance, to: url)
        }
        window.close()
    }

    private static func menuBar(_ model: AppModel, appearance: NSAppearance.Name, to url: URL) {
        let content = VStack(alignment: .trailing, spacing: 6) {
            FakeMenuBar(count: model.incompleteCount(listID: model.selectedListID) ?? 0)
            MenuBarView()
                .environment(model)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                .padding(.trailing, 64)
        }
        .padding(.bottom, 4)
        .frame(width: 520)

        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 520, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        let hosting = NSHostingView(rootView: content)
        window.contentView = hosting
        settle()
        window.setContentSize(hosting.fittingSize)
        window.orderFrontRegardless()
        settle()
        save(hosting, rounded: false, appearance: appearance, to: url)
        window.close()
    }

    /// `CGWindowListCreateImage` is hidden from the current SDK but still works for the app's own windows.
    private static func windowImage(_ window: NSWindow) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        let includingWindow: UInt32 = 1 << 3
        let ignoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        return fn(.null, includingWindow, UInt32(window.windowNumber), ignoreFraming | bestResolution)?.takeRetainedValue()
    }

    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    }

    /// Draws the view, then places it on a transparent canvas with a soft drop shadow.
    private static func save(_ view: NSView, rounded: Bool, appearance: NSAppearance.Name, to url: URL) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        compose(rep, size: bounds.size, rounded: rounded, appearance: appearance, to: url)
    }

    private static func compose(_ rep: NSBitmapImageRep, size: CGSize, rounded: Bool, appearance: NSAppearance.Name, to url: URL) {
        let bounds = CGRect(origin: .zero, size: size)
        let scale = CGFloat(rep.pixelsWide) / bounds.width

        let margin: CGFloat = 48
        let canvasSize = CGSize(width: bounds.width + margin * 2, height: bounds.height + margin * 2)
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvasSize.width * scale), pixelsHigh: Int(canvasSize.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        out.size = canvasSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let rect = NSRect(x: margin, y: margin, width: bounds.width, height: bounds.height)
        let radius: CGFloat = rounded ? 12 : 0
        let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        if rounded {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = NSSize(width: 0, height: -12)
            shadow.set()
            (appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor.white).setFill()
            clip.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        rep.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()

        if rounded {
            NSColor.black.withAlphaComponent(appearance == .darkAqua ? 0.6 : 0.15).setStroke()
            clip.lineWidth = 1
            clip.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        try? out.representation(using: .png, properties: [:])?.write(to: url)
        print("  wrote \(url.lastPathComponent)")
    }

    // MARK: Demo data

    private static func demoModel(pendingChanges: Int = 0, offline: Bool = false) -> AppModel {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func day(_ offset: Int) -> String { GDate.formatDue(cal.date(byAdding: .day, value: offset, to: today)!) }
        func done(_ hoursAgo: Double) -> String {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(-hoursAgo * 3600))
        }
        var n = 0
        func t(_ id: String, _ title: String, notes: String? = nil, due: String? = nil, parent: String? = nil,
               completed: String? = nil) -> GTask {
            n += 1
            return GTask(id: id, title: title, notes: notes, status: completed == nil ? "needsAction" : "completed",
                         due: due, completed: completed, parent: parent, position: String(format: "%020d", n))
        }

        let lists = [
            TaskList(id: "mine", title: "My Tasks"),
            TaskList(id: "work", title: "Work"),
            TaskList(id: "groceries", title: "Groceries"),
            TaskList(id: "travel", title: "Lisbon trip"),
        ]
        let tasks: [String: [GTask]] = [
            "mine": [
                t("m1", "Renew passport", notes: "Book an appointment online and bring two photos.", due: day(-1)),
                t("m2", "Plan Sarah's birthday dinner", notes: "Saturday at 7pm. Check the guest list with Tom.", due: day(0)),
                t("m2a", "Book a table for 6", parent: "m2"),
                t("m2b", "Order the cake", parent: "m2"),
                t("m3", "Call the dentist", due: day(1)),
                t("m4", "Pay electricity bill", notes: "Autopay failed last month, so pay manually.", due: day(3)),
                t("m5", "Back up photos to the NAS"),
                t("m6", "Read \"The Pragmatic Programmer\"", notes: "Chapters 4 to 6"),
                t("m7", "Water the plants", completed: done(2)),
                t("m8", "Return library books", completed: done(26)),
            ],
            "work": [
                t("w1", "Prepare Q4 roadmap slides", due: day(2)),
                t("w2", "Review pull requests", due: day(0)),
                t("w3", "1:1 notes for Friday"),
            ],
            "groceries": [
                t("g1", "Oat milk"), t("g2", "Avocados"), t("g3", "Coffee beans"),
                t("g4", "Sourdough bread"), t("g5", "Greek yoghurt"),
                t("g6", "Bananas", completed: done(1)),
            ],
            "travel": [
                t("t1", "Book flights", due: day(5)),
                t("t2", "Reserve a hotel in Alfama", due: day(7)),
            ],
        ]

        let model = AppModel(demo: true)
        model.loadDemo(lists: lists, tasks: tasks, selectedListID: "mine", selectedTaskID: "m2",
                       pendingChanges: pendingChanges, offline: offline,
                       lastSynced: Date().addingTimeInterval(offline ? -3600 : -20))
        model.showCompleted = true
        return model
    }
}

/// A stand-in for the right side of the macOS menu bar, to show the icon with its count.
private struct FakeMenuBar: View {
    let count: Int

    var body: some View {
        HStack(spacing: 18) {
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "checklist")
                Text("\(count)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.15)))
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Image(systemName: "switch.2")
            Text(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(.bar)
    }
}

/// Draws as the focused window, so controls aren't rendered in their dimmed inactive style.
private final class ActiveWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}
