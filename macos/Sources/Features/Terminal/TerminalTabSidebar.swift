import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Backing model for the native left sidebar that lists the tabs (windows) in a
/// terminal's tab group. This is used when `macos-tab-position = left`.
///
/// Tabs on macOS are managed as a native `NSWindowTabGroup` of separate windows.
/// This model mirrors that group so the sidebar can present and control it. Each
/// window in the group hosts its own sidebar/model, all reflecting the same shared
/// tab group, so they're kept in sync by calling `refresh()` from the controller
/// at the same points that drive native tab relabeling (key window changes, tab
/// add/remove, reorder).
@MainActor
class TabSidebarModel: ObservableObject {
    /// A single tab (window) in the group.
    struct Item: Identifiable {
        /// Stable identity derived from the window's object identity.
        let id: ObjectIdentifier
        let window: NSWindow
        let title: String
        /// 1-based position in the tab group.
        let index: Int
        /// The display string for the keyboard shortcut that activates this tab
        /// (e.g. "⌘1"), or nil if no shortcut is bound.
        let shortcut: String?
        /// Whether this tab is pinned. Pinned tabs are kept at the front of the
        /// tab group.
        let isPinned: Bool
    }

    /// The tabs in display order.
    @Published var tabs: [Item] = []

    /// The currently selected tab, if any.
    @Published var selectedID: ObjectIdentifier?

    /// The terminal background color, used to tint the sidebar so it reads as a
    /// seamless continuation of the terminal rather than blurring the desktop.
    @Published var terminalBackground: Color?

    /// The booted iOS simulators, mirrored from the shared `SimulatorManager`.
    /// Routing this through the per-window model (rather than observing the
    /// shared manager directly in the view) guarantees the hosted SwiftUI view
    /// re-renders when the list changes — the same path that reliably drives
    /// tab updates.
    @Published var simulators: [SimulatorManager.Simulator] = []

    /// Whether to show the "Simulators" section (`macos-tab-sidebar-simulators`).
    var showSimulators: Bool = false

    /// Combine subscription mirroring the shared simulator list into `simulators`.
    private var simulatorObservation: AnyCancellable?

    /// The window this sidebar belongs to. Weak because the window owns the
    /// controller which (transitively) owns this model.
    weak var window: NSWindow?

    /// The default thickness of the sidebar in points. Used both for the split
    /// view item and for sizing the window so the terminal content keeps its
    /// requested size.
    static let defaultWidth: CGFloat = 180
    static let minWidth: CGFloat = 140
    static let maxWidth: CGFloat = 320

    /// KVO observations of each tab window's title, so the sidebar reflects
    /// title changes from any source (rename dialog, keybind, shell-set titles).
    private var titleObservations: [NSKeyValueObservation] = []

    init(window: NSWindow?) {
        self.window = window
    }

    /// Enable the "Simulators" section: start the shared manager and mirror its
    /// booted-simulator list into this model so the sidebar updates live.
    func enableSimulators() {
        showSimulators = true
        let manager = SimulatorManager.shared
        manager.start()
        simulators = manager.simulators
        simulatorObservation = manager.$simulators
            .receive(on: RunLoop.main)
            .sink { [weak self] sims in
                self?.simulators = sims
            }
    }

    /// The windows in this tab's group, or just our window if there is no group.
    private func windowsInGroup() -> [NSWindow] {
        guard let window else { return [] }
        if let tabGroup = window.tabGroup, !tabGroup.windows.isEmpty {
            return tabGroup.windows
        }
        return [window]
    }

    /// Rebuild `tabs` and `selectedID` and re-arm title observations from the
    /// current tab group state.
    func refresh() {
        rebuildObservations()
        rebuildItems()
    }

    /// (Re)register KVO observers for the current set of tab windows' titles.
    private func rebuildObservations() {
        titleObservations.forEach { $0.invalidate() }
        titleObservations = windowsInGroup().map { w in
            w.observe(\.title, options: [.new]) { [weak self] _, _ in
                // A title changed; refresh the row contents. Observers don't
                // need rebuilding here since the window set hasn't changed.
                DispatchQueue.main.async { self?.rebuildItems() }
            }
        }
    }

    /// Rebuild the published `tabs`/`selectedID` from current window state.
    private func rebuildItems() {
        guard let window else {
            tabs = []
            selectedID = nil
            return
        }

        let config = (window.windowController as? BaseTerminalController)?.ghostty.config

        // Tint the sidebar with the terminal's background color AND opacity so it
        // matches the terminal exactly. preferredBackgroundColor already carries
        // the configured background-opacity in its alpha; fall back to the config
        // color + opacity when it isn't available yet (so we never go fully clear).
        let colorWindow = window.tabGroup?.selectedWindow ?? window
        if let tw = colorWindow as? TerminalWindow, let bg = tw.preferredBackgroundColor {
            terminalBackground = Color(nsColor: bg)
        } else if let config {
            terminalBackground = config.backgroundColor.opacity(config.backgroundOpacity)
        }
        let windows = windowsInGroup()

        tabs = windows.enumerated().map { offset, w in
            let index = offset + 1
            return Item(
                id: .init(w),
                window: w,
                title: title(for: w),
                index: index,
                shortcut: shortcut(for: index, config: config),
                isPinned: (w as? TerminalWindow)?.isPinned ?? false)
        }

        let selected = window.tabGroup?.selectedWindow ?? window
        selectedID = .init(selected)
    }

    deinit {
        titleObservations.forEach { $0.invalidate() }
    }

    /// Select the tab with the given id, bringing its window to the front and
    /// returning keyboard focus to its terminal surface.
    func select(_ id: ObjectIdentifier?) {
        guard let id, let item = tabs.first(where: { $0.id == id }) else { return }
        // Defer to the next runloop tick: this is often called from within a
        // SwiftUI binding setter, and mutating @Published state synchronously
        // there triggers "Publishing changes from within view updates" warnings.
        DispatchQueue.main.async {
            // Setting the selected window switches the visible tab in the group.
            self.window?.tabGroup?.selectedWindow = item.window
            item.window.makeKeyAndOrderFront(nil)
            self.selectedID = id
            self.focusSurface(in: item.window)
        }
    }

    /// Return keyboard focus to the terminal surface of the currently selected
    /// tab. Clicking the sidebar moves first responder to the list, which would
    /// otherwise leave keybindings (e.g. tab switching) non-functional.
    func refocus() {
        let target = window?.tabGroup?.selectedWindow ?? window
        guard let target else { return }
        focusSurface(in: target)
    }

    /// Rename the tab with the given id. An empty title restores the default.
    func rename(_ id: ObjectIdentifier, to newTitle: String) {
        guard let item = tabs.first(where: { $0.id == id }),
              let controller = item.window.windowController as? BaseTerminalController else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.titleOverride = trimmed.isEmpty ? nil : trimmed
        refresh()
        focusSurface(in: item.window)
    }

    /// Close the tab with the given id using the standard window close path so
    /// confirmation and the tab-group close coordinator are honored.
    func close(_ id: ObjectIdentifier) {
        guard let item = tabs.first(where: { $0.id == id }) else { return }
        item.window.performClose(nil)
    }

    /// Create a new tab in this window's tab group.
    func newTab() {
        (window?.windowController as? TerminalController)?.newWindowForTab(nil)
    }

    /// Pin or unpin the tab with the given id. Pinned tabs are reordered to the
    /// front of the tab group by the controller.
    func setPinned(_ id: ObjectIdentifier, pinned: Bool) {
        guard let item = tabs.first(where: { $0.id == id }),
              let controller = item.window.windowController as? TerminalController else { return }
        controller.setPinned(pinned, for: item.window)
        refresh()
    }

    /// Reorder the underlying tab group so its windows match the given order of
    /// tab ids. Called when a drag-to-reorder completes in the sidebar.
    ///
    /// Tabs are native windows in an `NSWindowTabGroup`, so reordering means
    /// repositioning the windows within the group. The currently selected tab
    /// is preserved across the reshuffle, and every window's sidebar (and tab
    /// keyboard shortcut) is refreshed so all tabs in the group stay in sync.
    func commitOrder(_ orderedIDs: [ObjectIdentifier]) {
        guard let tabGroup = window?.tabGroup else { return }
        let current = tabGroup.windows

        // Map each id back to its window, then build the desired window order.
        var byID: [ObjectIdentifier: NSWindow] = [:]
        for w in current { byID[.init(w)] = w }
        let desired = orderedIDs.compactMap { byID[$0] }

        // Bail if the order is incomplete or unchanged; still refresh so the
        // live-reordered SwiftUI state is reconciled with the real group order.
        guard desired.count == current.count, desired != current else {
            refreshGroup()
            return
        }

        // Reposition windows one slot at a time. At step `targetIndex` every
        // earlier slot already holds its final window, so removing `w` and
        // reinserting it at `targetIndex` lands it correctly. removeWindow can
        // disturb the selection, so we capture and restore it afterward.
        let previouslySelected = tabGroup.selectedWindow
        for (targetIndex, w) in desired.enumerated() {
            guard tabGroup.windows.firstIndex(of: w) != targetIndex else { continue }
            tabGroup.removeWindow(w)
            tabGroup.insertWindow(w, at: targetIndex)
        }
        if let previouslySelected {
            tabGroup.selectedWindow = previouslySelected
        }

        refreshGroup()
    }

    /// Refresh every window's sidebar model and tab keyboard shortcuts in this
    /// tab group. Used after a reorder, which affects all tabs in the group,
    /// not just this one.
    private func refreshGroup() {
        let windows = window?.tabGroup?.windows ?? [window].compactMap { $0 }
        for w in windows {
            (w.windowController as? TerminalController)?.relabelTabs()
        }
    }

    private func focusSurface(in window: NSWindow) {
        guard let controller = window.windowController as? BaseTerminalController,
              let surface = controller.focusedSurface else { return }
        // Defer slightly so this runs after AppKit has finished assigning first
        // responder to the sidebar list from the click; otherwise the list would
        // keep keyboard focus and terminal keybindings would stop working.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Ghostty.moveFocus(to: surface)
        }
    }

    private func shortcut(for index: Int, config: Ghostty.Config?) -> String? {
        guard index <= 9, let config else { return nil }
        return config.keyboardShortcut(for: "goto_tab:\(index)")?.description
    }

    private func title(for window: NSWindow) -> String {
        let t = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Terminal" : t
    }
}

// MARK: - Borderless split view

/// An `NSSplitView` with no visible divider, so the sidebar and terminal panes
/// meet seamlessly without a divider line.
class BorderlessSplitView: NSSplitView {
    override var dividerColor: NSColor { .clear }
    override var dividerThickness: CGFloat { 0 }
}

// MARK: - NSWindow helpers

extension NSWindow {
    /// The terminal content view. This is normally the window's content view,
    /// but when the tabs sidebar is enabled the terminal content is nested
    /// inside an `NSSplitViewController`, so we search the hierarchy.
    var terminalContentView: NSView? {
        if let direct = contentView as? TerminalViewContainer {
            return direct
        }
        return contentView?.firstDescendant(ofType: TerminalViewContainer.self)
    }

    /// The width occupied by the tabs sidebar, or 0 if there is no sidebar.
    var terminalSidebarWidth: CGFloat {
        guard let splitVC = contentViewController as? NSSplitViewController else {
            return 0
        }
        guard let sidebar = splitVC.splitViewItems.first(where: { $0.behavior == .sidebar }),
              !sidebar.isCollapsed else {
            return 0
        }
        let width = sidebar.viewController.view.frame.width
        return width > 0 ? width : TabSidebarModel.defaultWidth
    }
}

/// The native sidebar view listing the tabs in the group.
struct TerminalTabSidebarView: View {
    @ObservedObject var model: TabSidebarModel

    /// The row the pointer is currently over, used to reveal the close button.
    @State private var hoveredID: ObjectIdentifier?

    /// The tab currently being renamed inline, if any.
    @State private var editingID: ObjectIdentifier?

    /// The working title while renaming.
    @State private var draftTitle: String = ""

    /// The tab currently being dragged to reorder, if any.
    @State private var draggingID: ObjectIdentifier?

    /// Drives focus to the inline rename text field.
    @FocusState private var renameFieldFocused: Bool

    /// The simulator row the pointer is currently over.
    @State private var hoveredSimID: String?

    var body: some View {
        VStack(spacing: 0) {
            // A plain scrollable stack (not a List) is used deliberately: a
            // SwiftUI List is backed by an NSTableView, which becomes the window's
            // first responder when clicked and steals keyboard focus from the
            // terminal — breaking keybindings. A plain view hierarchy with tap
            // gestures doesn't take keyboard focus, so the terminal keeps it.
            // GeometryReader lets the content fill the viewport height so the
            // empty area below the last row is still a drop target: dragging a
            // tab into it drops the tab at the end. Without this, releasing a
            // drag past the last row would hit no drop target, the reorder
            // would never commit, and the row would snap back to its origin.
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            sectionHeader("Tabs")

                            ForEach(model.tabs) { tab in
                                row(tab)
                            }

                            if model.showSimulators, !model.simulators.isEmpty {
                                sectionHeader("Simulators")
                                    .padding(.top, 8)

                                ForEach(Array(model.simulators.enumerated()), id: \.element.id) { index, sim in
                                    simulatorRow(sim, index: index)
                                }
                            }
                        }

                        // Transparent catcher that fills the remaining space and
                        // moves the dragged tab to the end on drop.
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onDrop(
                                of: [.text],
                                delegate: TabReorderEndDropDelegate(
                                    model: model,
                                    draggingID: $draggingID))
                    }
                    .padding(8)
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
                // Keep the scroll content transparent so the native sidebar
                // material (liquid glass on macOS 26) shows through.
                .scrollContentBackground(.hidden)
            }

            Divider()
                .opacity(0.5)

            HStack {
                newTabButton
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Tint with the terminal's background color so the sidebar reads as a
        // seamless continuation of the terminal rather than blurring the desktop.
        // The color carries the terminal's alpha, so glass still shows through
        // when background-opacity < 1, and it's solid when opacity is disabled.
        .background(model.terminalBackground ?? .clear)
    }

    /// A small uppercased section heading, matching the standard sidebar look.
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .opacity(0.5)
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A row for a booted simulator. The first nine get a ⌘⌥<n> shortcut badge.
    private func simulatorRow(_ sim: SimulatorManager.Simulator, index: Int) -> some View {
        let isHovered = hoveredSimID == sim.id
        let shortcut = index < 9 ? "⌘⌥\(index + 1)" : nil

        return HStack(spacing: 8) {
            Text(shortcut ?? " ")
                .font(.system(.caption, design: .rounded))
                .opacity(0.7)
                .frame(minWidth: 32, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(sim.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(sim.osVersion)
                    .font(.caption2)
                    .opacity(0.5)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isSelected: false, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredSimID = inside ? sim.id : (hoveredSimID == sim.id ? nil : hoveredSimID)
        }
        // Tap to bring the simulator window to the front. Like tab rows, this
        // doesn't take keyboard focus away from the terminal.
        .onTapGesture {
            SimulatorManager.shared.focus(sim)
        }
        .help("Bring \(sim.name) to the front")
    }

    @ViewBuilder
    private var newTabButton: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Button(action: { model.newTab() }) {
                Image(systemName: "plus")
            }
            .buttonStyle(.glass)
            .help("New Tab")
        } else {
            legacyNewTabButton
        }
#else
        legacyNewTabButton
#endif
    }

    private var legacyNewTabButton: some View {
        Button(action: { model.newTab() }) {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("New Tab")
    }

    private func row(_ tab: TabSidebarModel.Item) -> some View {
        let isSelected = model.selectedID == tab.id
        let isHovered = hoveredID == tab.id

        return HStack(spacing: 8) {
            // Leading badge showing the keyboard shortcut (e.g. ⌘1). Falls back
            // to the tab's position when no shortcut is bound (e.g. tabs > 9).
            Text(tab.shortcut ?? "\(tab.index)")
                .font(.system(.caption, design: .rounded))
                .opacity(0.7)
                .frame(minWidth: 24, alignment: .leading)

            // Persistent indicator for pinned tabs, shown to the left of the title.
            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .imageScale(.small)
                    .opacity(0.6)
                    .help("Pinned")
            }

            if editingID == tab.id {
                TextField("", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename(tab) }
                    .onExitCommand { cancelRename() }
            } else {
                Text(tab.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isSelected: isSelected, isHovered: isHovered))
        .contentShape(Rectangle())
        // Dim the row while it's the one being dragged to reorder.
        .opacity(draggingID == tab.id ? 0.5 : 1)
        .onHover { inside in
            hoveredID = inside ? tab.id : (hoveredID == tab.id ? nil : hoveredID)
        }
        // Tap to select. This does not take keyboard focus, and select() also
        // returns focus to the terminal surface.
        .onTapGesture {
            if editingID == nil { model.select(tab.id) }
        }
        // Drag to reorder. Disabled while inline-renaming so the text field
        // keeps normal text-selection behavior. The drop delegate reorders the
        // rows live; the new order is committed to the tab group on drop.
        .onDrag {
            guard editingID != tab.id else { return NSItemProvider() }
            draggingID = tab.id
            return NSItemProvider(object: tab.title as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: TabReorderDropDelegate(
                item: tab,
                model: model,
                draggingID: $draggingID))
        .contextMenu {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") {
                model.setPinned(tab.id, pinned: !tab.isPinned)
            }
            Button("Rename…") { startRename(tab) }
            Button("Close Tab") { model.close(tab.id) }
        }
    }

    /// The row background. The selected row uses liquid glass on macOS 26 and a
    /// solid selection fill on older systems. Hover uses a subtle wash.
    @ViewBuilder
    private func rowBackground(isSelected: Bool, isHovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if isSelected {
                shape
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(.accentColor.opacity(0.45)).interactive(),
                        in: shape)
            } else {
                shape.fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            }
        } else {
            legacyRowBackground(isSelected: isSelected, isHovered: isHovered, shape: shape)
        }
#else
        legacyRowBackground(isSelected: isSelected, isHovered: isHovered, shape: shape)
#endif
    }

    private func legacyRowBackground(
        isSelected: Bool,
        isHovered: Bool,
        shape: RoundedRectangle
    ) -> some View {
        let color: Color = if isSelected {
            Color(nsColor: .selectedContentBackgroundColor)
        } else if isHovered {
            Color.primary.opacity(0.08)
        } else {
            Color.clear
        }
        return shape.fill(color)
    }

    private func startRename(_ tab: TabSidebarModel.Item) {
        guard editingID != tab.id else { return }
        draftTitle = tab.title
        editingID = tab.id
        DispatchQueue.main.async { renameFieldFocused = true }
    }

    private func commitRename(_ tab: TabSidebarModel.Item) {
        model.rename(tab.id, to: draftTitle)
        editingID = nil
    }

    private func cancelRename() {
        editingID = nil
        model.refocus()
    }
}

// MARK: - Drag-to-reorder

/// Drop delegate that reorders the sidebar's tab rows as a dragged tab is moved
/// over them, then commits the final order to the native tab group on drop.
///
/// The reorder is performed live against the model's published `tabs` array so
/// the rows animate into place under the pointer; `commitOrder` then makes the
/// underlying `NSWindowTabGroup` match what the user sees.
private struct TabReorderDropDelegate: DropDelegate {
    /// The row this delegate is attached to (the potential drop target).
    let item: TabSidebarModel.Item
    let model: TabSidebarModel

    /// The tab currently being dragged, shared with the view.
    @Binding var draggingID: ObjectIdentifier?

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != item.id,
              let from = model.tabs.firstIndex(where: { $0.id == draggingID }),
              let to = model.tabs.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            model.tabs.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggingID = nil }
        model.commitOrder(model.tabs.map(\.id))
        return true
    }
}

/// Drop delegate for the empty area below the last tab row. Dragging into it
/// moves the dragged tab to the end of the list; dropping commits the order.
/// This makes "drag to the very bottom" land the tab last, instead of leaving
/// the drag with no target (which would never commit and snap back).
private struct TabReorderEndDropDelegate: DropDelegate {
    let model: TabSidebarModel

    @Binding var draggingID: ObjectIdentifier?

    func dropEntered(info: DropInfo) {
        guard let draggingID,
              let from = model.tabs.firstIndex(where: { $0.id == draggingID }),
              from != model.tabs.count - 1 else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            model.tabs.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: model.tabs.count)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggingID = nil }
        model.commitOrder(model.tabs.map(\.id))
        return true
    }
}
