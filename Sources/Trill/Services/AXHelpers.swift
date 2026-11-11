import Foundation
import ApplicationServices

/// Thin, defensive wrappers over the C Accessibility API. Never throws, never crashes.
enum AX {
    static func copy(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return err == .success ? v : nil
    }

    static func errorCode(_ el: AXUIElement, _ name: String) -> AXError {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v)
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = copy(el, name) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let a = v as? NSAttributedString { return a.string }
        return nil
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        elements(el, "AXChildren")
    }

    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let arr = copy(el, name) as? [AnyObject] else { return [] }
        return arr.compactMap { o in
            CFGetTypeID(o) == AXUIElementGetTypeID() ? unsafeBitCast(o, to: AXUIElement.self) : nil
        }
    }

    static func attributeNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(el, &names) == .success, let n = names as? [String] else { return [] }
        return n
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let v = copy(el, "AXFrame"), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        let av = unsafeBitCast(v, to: AXValue.self)
        return AXValueGetValue(av, .cgRect, &r) ? r : nil
    }

    static func role(_ el: AXUIElement) -> String { string(el, "AXRole") ?? "" }
    static func subrole(_ el: AXUIElement) -> String { string(el, "AXSubrole") ?? "" }
}
