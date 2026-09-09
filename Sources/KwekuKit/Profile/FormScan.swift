import AppKit
import ApplicationServices

/// Noticing, without being asked, that Omari is sitting in front of a form
/// Kweku could fill.
///
/// `fill_field` gave him the hands and `PersonalProfile` gave him the facts,
/// but the offer still only happened if the conversation wandered past it. The
/// standard is the opposite: a companion watching him retype his own email
/// should speak first. Something has to actually look.
///
/// **It looks through Accessibility, not through the camera.** That is the
/// whole design. An unprompted turn injected with `clientContent` cannot see
/// the video stream, so a vision-based watcher would have to describe the form
/// to a model that can't check the description — the same trap `TriageTrigger`
/// walked into. The AX tree is read here, locally, and only the conclusion is
/// sent. It is also exact where vision is approximate: a label is a string, not
/// an inference, and "is this box empty" is a value read rather than a guess.
/// As a bonus it works with Screen Recording switched off entirely.
///
/// **Values are never touched.** The scan is handed the *names* of what Kweku
/// holds and returns the *names* that match. Nothing here can read the profile
/// even if it wanted to — which is what keeps the offer honest.
public enum FormScan {

    /// One editable control, as read off the screen.
    public struct Field: Equatable, Sendable {
        public let label: String
        public let isEmpty: Bool

        public init(label: String, isEmpty: Bool) {
            self.label = label
            self.isEmpty = isEmpty
        }
    }

    /// What a scan concluded about the window in front of him.
    public struct Form: Equatable, Sendable {
        public let app: String

        /// Canonical keys that are on screen, empty, and on file — exactly what
        /// there is to offer. Sorted, so a prompt reads the same every time.
        public let offerable: [String]

        /// Every empty editable field, recognised or not. This is what separates
        /// a five-question application from a newsletter box.
        public let emptyCount: Int

        /// Identity of the form, used to offer once and then let it go.
        public let signature: String
    }

    /// How often the window in front of him is worth re-reading. Slow enough
    /// that a few hundred Accessibility reads stay invisible, fast enough that
    /// the offer still lands while he's looking at the first empty box.
    public static let pollInterval: TimeInterval = 3

    // MARK: - The conclusion (pure, so it can be tested without a screen)

    /// Fold a window's fields into a verdict about the form.
    ///
    /// `holding` is the set of canonical keys Kweku has values for — names
    /// only. A field is offerable when it is recognised, empty, and held; all
    /// three, or there is nothing to say.
    public static func read(app: String, fields: [Field], holding: Set<String>) -> Form {
        var offerable: Set<String> = []
        var recognised: Set<String> = []
        var empty = 0
        for field in fields {
            if field.isEmpty { empty += 1 }
            guard let key = PersonalProfile.canonicalKey(for: field.label) else { continue }
            recognised.insert(key)
            if field.isEmpty, holding.contains(key) { offerable.insert(key) }
        }
        // The signature spans every field recognised on the form, filled or
        // not, rather than only the empty ones. Watching him type his email in
        // must not turn the same page into a different form and earn a second
        // offer — the one thing more annoying than never offering.
        let signature = ([app] + recognised.sorted()).joined(separator: "|")
        return Form(app: app,
                    offerable: offerable.sorted(),
                    emptyCount: empty,
                    signature: signature)
    }

    // MARK: - The looking

    /// Read the focused window of the frontmost app. Returns nil when there is
    /// nothing to look at, no permission to look with, or no form in sight.
    ///
    /// Safe to call off the main thread — Accessibility reads block, and a few
    /// hundred of them do not belong on the thread drawing the notch. Only the
    /// value type comes back, so nothing thread-hostile escapes.
    public static func frontmost(holding: Set<String>, limit: Int = 200) -> Form? {
        guard !holding.isEmpty else { return nil }
        // Deliberately the *silent* trust check, unlike every other AX call in
        // this app. The rest run because Omari just asked for something, so the
        // System Settings prompt is an answer; this one runs on a timer, and a
        // permission dialog nobody asked for is the definition of the problem
        // this feature exists to avoid.
        guard AXIsProcessTrusted() else { return nil }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let root = AXUIElementCreateApplication(front.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                root, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let found = value, CFGetTypeID(found) == AXUIElementGetTypeID()
        else { return nil }

        let fields = editableFields(under: found as! AXUIElement, limit: limit)
        guard !fields.isEmpty else { return nil }
        return read(app: front.localizedName ?? "", fields: fields, holding: holding)
    }

    /// Breadth-first, and bounded twice over: a page like a job board has
    /// thousands of nodes, and the fields worth finding are never deep in the
    /// tail of it. Stopping early costs a missed offer on a pathological page
    /// and saves a stall on every ordinary one.
    static func editableFields(under root: AXUIElement, limit: Int) -> [Field] {
        var fields: [Field] = []
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < limit, fields.count < 24 {
            let element = queue.removeFirst()
            visited += 1
            let role = FieldFill.string(from: element, attribute: kAXRoleAttribute as String) ?? ""
            if FieldFill.editableRoles.contains(role) {
                let text = FieldFill.string(from: element, attribute: kAXValueAttribute as String) ?? ""
                fields.append(Field(
                    label: label(of: element),
                    isEmpty: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                // A text field's children are its own text runs, not more
                // fields. Descending into them buys nothing and costs the budget.
                continue
            }
            queue.append(contentsOf: children(of: element))
        }
        return fields
    }

    /// What the form calls this field.
    ///
    /// Pages label an input in four different places depending on how they were
    /// written, and which one is populated is not predictable from the outside:
    /// a hand-written form tends to have a real `<label>` (arriving as a
    /// separate element the field points at), a component library tends to have
    /// only a placeholder. So all four are tried, cheapest first, and the first
    /// non-empty one wins. An unlabelled field returns "", which resolves to no
    /// canonical key and is therefore ignored rather than guessed at.
    static func label(of element: AXUIElement) -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
            if let text = FieldFill.string(from: element, attribute: attribute as String),
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text
            }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXTitleUIElementAttribute as CFString, &value) == .success,
              let found = value, CFGetTypeID(found) == AXUIElementGetTypeID()
        else { return "" }
        let titleElement = found as! AXUIElement
        for attribute in [kAXValueAttribute, kAXTitleAttribute] {
            if let text = FieldFill.string(from: titleElement, attribute: attribute as String),
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text
            }
        }
        return ""
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement]
        else { return [] }
        return array
    }
}
