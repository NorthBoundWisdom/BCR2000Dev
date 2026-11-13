import AppKit
import BCRFoundation
import SwiftUI

/// Test presentation carrier only. Product launches retain native Menu/sheet/confirmationDialog.
/// A panel that cannot become key/main cannot take the desktop's keyboard focus.
@MainActor
final class OffscreenInteractionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
enum OffscreenInteractionPanel {
    private(set) static var window: OffscreenInteractionWindow?
    private static var identifier: String?

    static func present(id: String, view: AnyView) {
        guard OffscreenPresentation.isEnabled else { return }
        let root = AnyView(view.background(Theme.background).preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: L10n.language.rawValue)))
        if identifier == id, let host = window?.contentView as? NSHostingView<AnyView> {
            host.rootView = root
            return
        }
        dismiss()
        let panel = OffscreenInteractionWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 700),
                                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                                               defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.title = "Offscreen test interaction"
        let host = NSHostingView(rootView: root)
        panel.contentView = host
        let size = host.fittingSize
        panel.setContentSize(NSSize(width: max(size.width, 1), height: max(size.height, 1)))
        OffscreenPresentation.apply(to: panel)
        identifier = id
        window = panel
        panel.orderBack(nil)
    }

    static func dismiss(id: String? = nil) {
        guard id == nil || id == identifier else { return }
        window?.orderOut(nil)
        window?.close()
        window = nil
        identifier = nil
    }
}

private struct OffscreenPanelPresenter: NSViewRepresentable {
    let id: String
    let isPresented: Bool
    let view: AnyView

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {
        if isPresented { OffscreenInteractionPanel.present(id: id, view: view) }
        else { OffscreenInteractionPanel.dismiss(id: id) }
    }
}

struct OffscreenSafeMenu<Actions: View, Label: View>: View {
    let id: String
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let label: () -> Label

    var body: some View {
        if OffscreenPresentation.isEnabled {
            Button {
                OffscreenInteractionPanel.present(id: id, view: AnyView(VStack(alignment: .leading, spacing: 12) {
                    actions()
                }.padding(20).frame(width: 480)))
            } label: { label() }
        } else {
            Menu(content: actions, label: label)
        }
    }
}

extension View {
    @ViewBuilder
    func offscreenSafeSheet<Sheet: View>(id: String, isPresented: Binding<Bool>,
                                         @ViewBuilder content: @escaping () -> Sheet) -> some View
    {
        if OffscreenPresentation.isEnabled {
            background(OffscreenPanelPresenter(id: id, isPresented: isPresented.wrappedValue,
                                               view: AnyView(content())).frame(width: 0, height: 0))
        } else {
            sheet(isPresented: isPresented, content: content)
        }
    }

    @ViewBuilder
    func offscreenSafeSheet<Item: Identifiable, Sheet: View>(id: String, item: Binding<Item?>,
                                                             @ViewBuilder content: @escaping (Item) -> Sheet)
        -> some View
    {
        if OffscreenPresentation.isEnabled {
            background(OffscreenPanelPresenter(id: id, isPresented: item.wrappedValue != nil,
                                               view: AnyView(Group {
                                                   if let value = item.wrappedValue { content(value) }
                                               })).frame(width: 0, height: 0))
        } else {
            sheet(item: item, content: content)
        }
    }

    @ViewBuilder
    func offscreenSafeConfirmationDialog<Item, Actions: View, Message: View>(
        id: String, _ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility,
        presenting: Item?, @ViewBuilder actions: @escaping (Item) -> Actions,
        @ViewBuilder message: @escaping (Item) -> Message
    ) -> some View {
        if OffscreenPresentation.isEnabled {
            background(OffscreenPanelPresenter(id: id, isPresented: isPresented.wrappedValue,
                                               view: AnyView(VStack(alignment: .leading, spacing: 16) {
                                                   if let value = presenting {
                                                       Text(title).font(.headline)
                                                       message(value)
                                                       HStack { actions(value) }
                                                   }
                                               }.padding(24).frame(width: 520))).frame(width: 0, height: 0))
        } else {
            confirmationDialog(title, isPresented: isPresented, titleVisibility: titleVisibility,
                               presenting: presenting, actions: actions, message: message)
        }
    }
}
