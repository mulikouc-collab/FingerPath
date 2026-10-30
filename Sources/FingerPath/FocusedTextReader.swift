import AppKit
import ApplicationServices

// MARK: - 辅助功能读取

struct FocusedTextSnapshot: Codable, Sendable {
    /// 光标所在段落（打字翻译用）。
    let text: String
    /// 选中的文字；没有选中时为 nil。
    let selectedText: String?
    /// 输入框可编辑（排除「Claude 正在回复」这类界面文字）。
    let isEditable: Bool
    let textMinX, textMinY, textMaxX, textMaxY: Double
    let selMinX, selMinY, selMaxX, selMaxY: Double
    /// 整个输入框的位置。
    let elMinX, elMinY, elMaxX, elMaxY: Double
    /// 光标所在那一行。
    let caretMinX, caretMinY, caretMaxX, caretMaxY: Double
    /// 用来判断是不是换了一个输入框。
    let elementID: UInt
    let processIdentifier: pid_t

    var textFrame: CGRect { Self.rect(textMinX, textMinY, textMaxX, textMaxY) }
    var selectionFrame: CGRect { Self.rect(selMinX, selMinY, selMaxX, selMaxY) }
    var elementFrame: CGRect { Self.rect(elMinX, elMinY, elMaxX, elMaxY) }
    var caretLineFrame: CGRect { Self.rect(caretMinX, caretMinY, caretMaxX, caretMaxY) }

    private static func rect(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> CGRect {
        guard maxX > minX, maxY > minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

enum FocusedTextReader {
    private static let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    static func read() -> FocusedTextSnapshot? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        guard let focused: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.4)
        let subrole: String? = attribute(focused, kAXSubroleAttribute)
        guard subrole != "AXSecureTextField" else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)

        let role: String = attribute(focused, kAXRoleAttribute) ?? ""
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        let hasEditableAncestor: AXUIElement? = attribute(focused, "AXEditableAncestor")
        let isEditable = editableRoles.contains(role) || settable.boolValue || hasEditableAncestor != nil

        let selectedRange = rangeAttribute(focused, kAXSelectedTextRangeAttribute)
        var selected: String? = attribute(focused, kAXSelectedTextAttribute)
        if selected?.isEmpty == true { selected = nil }
        var selectionFrame = selected != nil
            ? selectedRange.flatMap { bounds(for: focused, range: $0) } ?? .zero
            : .zero
        // 网页 / Electron：在聊天记录里选字时，焦点常常还在输入框，
        // 要去整个页面（AXWebArea）用 TextMarker 接口取选区。
        if selected == nil, let web = webSelection(from: focused) {
            selected = web.text
            selectionFrame = web.frame
        }

        var paragraph = ""
        var textFrame = CGRect.zero
        var caretLine = CGRect.zero
        if isEditable, let value: String = attribute(focused, kAXValueAttribute), !value.isEmpty {
            let nsValue = value as NSString
            let caret = max(0, min(selectedRange?.location ?? nsValue.length, nsValue.length))
            let probe = NSRange(location: min(caret, max(nsValue.length - 1, 0)), length: 0)
            let range = nsValue.paragraphRange(for: probe)
            paragraph = nsValue.substring(with: range)
            textFrame = bounds(for: focused, range: CFRange(location: range.location, length: range.length)) ?? .zero
            // 光标前一个字所在的行。
            let charBefore = CFRange(location: max(0, caret - 1), length: caret > 0 ? 1 : 0)
            caretLine = bounds(for: focused, range: charBefore) ?? .zero
        }
        let element = elementFrame(focused) ?? .zero

        guard selected != nil || !paragraph.isEmpty else { return nil }
        return FocusedTextSnapshot(
            text: paragraph,
            selectedText: selected,
            isEditable: isEditable,
            textMinX: textFrame.minX, textMinY: textFrame.minY,
            textMaxX: textFrame.maxX, textMaxY: textFrame.maxY,
            selMinX: selectionFrame.minX, selMinY: selectionFrame.minY,
            selMaxX: selectionFrame.maxX, selMaxY: selectionFrame.maxY,
            elMinX: element.minX, elMinY: element.minY, elMaxX: element.maxX, elMaxY: element.maxY,
            caretMinX: caretLine.minX, caretMinY: caretLine.minY,
            caretMaxX: caretLine.maxX, caretMaxY: caretLine.maxY,
            elementID: UInt(CFHash(focused)),
            processIdentifier: pid
        )
    }

    /// 从焦点元素往上找到网页根节点，读取页面里选中的文字和位置（Chrome、Safari、Electron 支持）。
    private static func webSelection(from focused: AXUIElement) -> (text: String, frame: CGRect)? {
        var current: AXUIElement? = focused
        var webArea: AXUIElement?
        for _ in 0..<40 {
            guard let element = current else { break }
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" { webArea = element }
            // 继续往上找最外层的 WebArea（iframe 里也有 WebArea）。
            if role == "AXWindow" || role == "AXApplication" { break }
            current = attribute(element, kAXParentAttribute)
        }
        guard let webArea else { return nil }
        AXUIElementSetMessagingTimeout(webArea, 0.4)

        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            webArea, "AXSelectedTextMarkerRange" as CFString, &markerRange
        ) == .success, let markerRange else { return nil }

        var textRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            webArea, "AXStringForTextMarkerRange" as CFString, markerRange, &textRef
        ) == .success, let text = textRef as? String,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var frame = CGRect.zero
        var boundsRef: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            webArea, "AXBoundsForTextMarkerRange" as CFString, markerRange, &boundsRef
        ) == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(unsafeDowncast(boundsRef, to: AXValue.self), .cgRect, &rect),
               rect.width > 0, rect.height > 0 {
                let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                frame = CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
            }
        }
        return (text, frame)
    }

    /// 输入框在屏幕上的位置（AXPosition + AXSize），换算成 AppKit 坐标。
    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionRef, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(sizeRef, to: AXValue.self), .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: origin.x, y: primaryTop - origin.y - size.height, width: size.width, height: size.height)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func rangeAttribute(_ element: AXUIElement, _ name: String) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    /// 文字范围的屏幕位置，换算成 AppKit 坐标（左下角为原点）。
    private static func bounds(for element: AXUIElement, range: CFRange) -> CGRect? {
        var range = range
        guard range.length >= 0, let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            parameter,
            &raw
        ) == .success,
        let raw,
        CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect), rect.width > 0, rect.height > 0 else { return nil }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
}
