import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?
    private var popup: PopupController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        popup = PopupController()
        requestAccessibility()
        registerHotKey()
    }

    private func requestAccessibility() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func registerHotKey() {
        let eventHotKeyID = EventHotKeyID(signature: OSType(0x50494E59), id: 1)

        RegisterEventHotKey(
            UInt32(kVK_ANSI_P),
            UInt32(controlKey | optionKey | cmdKey),
            eventHotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()

                var hotKey = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKey
                )

                if status == noErr && hotKey.id == 1 {
                    delegate.handleHotkey()
                }

                return noErr
            },
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            nil
        )
    }

    private func handleHotkey() {
        let mouseLocation = NSEvent.mouseLocation

        guard AXIsProcessTrusted() else {
            popup.show(text: "Enable Accessibility", near: nil, cursor: mouseLocation)
            return
        }

        let anchorRect = selectedTextBoundsFromAccessibility()
        let pasteboard = NSPasteboard.general
        let oldChangeCount = pasteboard.changeCount

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }

            self.simulateCommandC()

            self.waitForClipboardChange(
                originalChangeCount: oldChangeCount,
                timeout: 0.75,
                interval: 0.03
            ) { [weak self] changed in
                guard let self else { return }

                if !changed {
                    self.popup.show(text: "Nothing copied", near: anchorRect, cursor: mouseLocation)
                    return
                }

                let copiedText = pasteboard.string(forType: .string) ?? ""
                let normalized = copiedText.replacingOccurrences(of: "\r\n", with: "\n")
                let cleaned = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !cleaned.isEmpty else {
                    self.popup.show(text: "No text copied", near: anchorRect, cursor: mouseLocation)
                    return
                }

                let pinyin = cleaned.toPinyinWithToneMarks()
                self.popup.show(text: pinyin, near: anchorRect, cursor: mouseLocation)
            }
        }
    }

    private func waitForClipboardChange(
        originalChangeCount: Int,
        timeout: TimeInterval,
        interval: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        let pasteboard = NSPasteboard.general
        let deadline = Date().addingTimeInterval(timeout)

        func check() {
            if pasteboard.changeCount != originalChangeCount {
                completion(true)
                return
            }

            if Date() >= deadline {
                completion(false)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                check()
            }
        }

        check()
    }

    private func simulateCommandC() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_C),
            keyDown: true
        )
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_C),
            keyDown: false
        )

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func selectedTextBoundsFromAccessibility() -> CGRect? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedObject: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )

        guard focusedResult == .success, let focusedObject else {
            return nil
        }

        let element = focusedObject as! AXUIElement

        var rangeValue: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )

        guard rangeResult == .success, let rangeValue else {
            return nil
        }

        guard CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }

        let rangeAXValue = rangeValue as! AXValue
        guard AXValueGetType(rangeAXValue) == .cfRange else {
            return nil
        }

        var cfRange = CFRange()
        guard AXValueGetValue(rangeAXValue, .cfRange, &cfRange) else {
            return nil
        }

        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            return nil
        }

        var boundsValue: CFTypeRef?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            parameter,
            &boundsValue
        )

        guard boundsResult == .success, let boundsValue else {
            return nil
        }

        guard CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }

        let boundsAXValue = boundsValue as! AXValue
        guard AXValueGetType(boundsAXValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsAXValue, .cgRect, &rect) else {
            return nil
        }

        return rect
    }
}
final class PopupController {
    private let window: NSPanel
    private let contentView: NSView
    private let label: NSTextField

    private let paddingX: CGFloat = 10
    private let paddingY: CGFloat = 1
    private let glyphSafetyX: CGFloat = 2
    private let glyphSafetyY: CGFloat = 1

    private var hideWorkItem: DispatchWorkItem?

    init() {
        label = NSTextField(labelWithString: "")
        label.font = PopupController.preferredFont()
        label.alignment = .left
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.usesSingleLineMode = false
        label.textColor = .labelColor
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.cell?.truncatesLastVisibleLine = false

        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.isFloatingPanel = true
        window.level = .statusBar
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 8
        contentView.layer?.masksToBounds = false
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor

        window.contentView = contentView
        contentView.addSubview(label)
    }

    func show(text: String, near selectionBounds: CGRect?, cursor: CGPoint?) {
        guard let screen = bestScreen(selectionBounds: selectionBounds, cursor: cursor) ?? NSScreen.main else {
            return
        }

        label.font = PopupController.preferredFont()
        label.stringValue = text

        let visible = screen.visibleFrame
        let maxPopupWidth = max(220, floor(visible.width * 0.30))

        let natural = measure(text: text, width: 100000)
        let shouldWrap = natural.width + paddingX * 2 + glyphSafetyX * 2 > maxPopupWidth

        let textWidth: CGFloat = shouldWrap
            ? (maxPopupWidth - paddingX * 2 - glyphSafetyX * 2)
            : natural.width

        let measured = measure(text: text, width: textWidth)

        let finalTextWidth = ceil(measured.width + glyphSafetyX * 2)
        let finalTextHeight = ceil(measured.height + glyphSafetyY * 2)

        let popupWidth = ceil(finalTextWidth + paddingX * 2)
        let popupHeight = ceil(finalTextHeight + paddingY * 2)

        window.setContentSize(NSSize(width: popupWidth, height: popupHeight))
        contentView.frame = NSRect(x: 0, y: 0, width: popupWidth, height: popupHeight)

        label.frame = NSRect(
            x: paddingX,
            y: paddingY,
            width: finalTextWidth,
            height: finalTextHeight
        )

        var origin = popupOrigin(
            popupSize: NSSize(width: popupWidth, height: popupHeight),
            selectionBounds: selectionBounds,
            cursor: cursor,
            screen: screen
        )

        if origin.x < visible.minX { origin.x = visible.minX }
        if origin.x + popupWidth > visible.maxX { origin.x = visible.maxX - popupWidth }
        if origin.y < visible.minY { origin.y = visible.minY }
        if origin.y + popupHeight > visible.maxY { origin.y = visible.maxY - popupHeight }

        window.setFrameOrigin(origin)
        window.invalidateShadow()
        window.orderFrontRegardless()

        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.window.orderOut(nil)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: workItem)
    }

    private func measure(text: String, width: CGFloat) -> NSSize {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping

        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: label.font as Any,
                .paragraphStyle: paragraph
            ]
        )

        let rect = attributed.boundingRect(
            with: NSSize(width: width, height: 100000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        return NSSize(
            width: ceil(rect.width),
            height: ceil(rect.height)
        )
    }

    private func popupOrigin(
        popupSize: NSSize,
        selectionBounds: CGRect?,
        cursor: CGPoint?,
        screen: NSScreen
    ) -> CGPoint {
        if let selectionBounds {
            let appKitRect = convertAccessibilityRectToAppKit(selectionBounds, on: screen)
            return CGPoint(
                x: appKitRect.midX - popupSize.width / 2,
                y: appKitRect.minY - popupSize.height - 8
            )
        }

        if let cursor {
            return CGPoint(
                x: cursor.x,
                y: cursor.y + 10
            )
        }

        let visible = screen.visibleFrame
        return CGPoint(
            x: visible.midX - popupSize.width / 2,
            y: visible.midY - popupSize.height / 2
        )
    }

    private func bestScreen(selectionBounds: CGRect?, cursor: CGPoint?) -> NSScreen? {
        if let rect = selectionBounds,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
            return screen
        }

        if let cursor,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) {
            return screen
        }

        return NSScreen.main
    }

    private func convertAccessibilityRectToAppKit(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        let screenFrame = screen.frame
        return CGRect(
            x: rect.origin.x,
            y: screenFrame.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func preferredFont() -> NSFont {
        if let f = NSFont(name: "Alegreya Sans", size: 16) {
            return f
        }
        if let f = NSFont(name: "Cormorant Garamond", size: 17) {
            return f
        }
        if let f = NSFont(name: "Palatino", size: 16) {
            return f
        }
        return NSFont.systemFont(ofSize: 16, weight: .regular)
    }
}

extension String {
    func toPinyinWithToneMarks() -> String {
        let mutable = NSMutableString(string: self) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)

        return (mutable as String)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()