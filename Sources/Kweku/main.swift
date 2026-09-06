// ─────────────────────────────────────────────────────────────────────────────
//  FROZEN HOST — think twice before editing this file.
//
//  Kweku is ad-hoc signed, so macOS derives the app's designated requirement
//  from the bundle's cdhash:
//
//      designated => identifier "com.kweku.app" and cdhash H"f04407e5…"
//
//  That hash seals this executable, Info.plist, the entitlements and
//  CodeResources. TCC stores Screen Recording / Microphone / Accessibility
//  grants against the requirement — so *any* change inside the bundle makes
//  Kweku a brand-new app to macOS, and every permission you granted is
//  forgotten. Rebuilding three times in an afternoon means re-granting three
//  times.
//
//  The fix is to stop putting churning code inside the seal. This file is
//  deliberately inert: it finds KwekuKit.dylib, loads it and jumps in. The
//  dylib lives OUTSIDE the bundle, so rebuilding it leaves the cdhash — and
//  therefore every permission — untouched. `make app` rebuilds only the dylib.
//
//  Editing this file, Resources/Info.plist or Resources/Kweku.entitlements
//  means `make host`, which re-freezes the bundle at a new hash and costs one
//  round of re-granting permissions. Everything else is free.
//
//  Once the app is signed with a real certificate the requirement becomes
//  cert-based rather than hash-based and none of this matters — at that point
//  ship the dylib inside Contents/Resources (the fallback below already looks
//  there) and delete this scheme.
// ─────────────────────────────────────────────────────────────────────────────

import AppKit

private let dylibName = "KwekuKit.dylib"

/// Development: the churning library, deliberately outside the signature seal.
private var developmentDylib: String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask)[0]
    return base.appendingPathComponent("Kweku/lib/\(dylibName)").path
}

/// Distribution: bundled and sealed, which is correct once a real signing
/// certificate makes the designated requirement cert-based instead of a hash.
private var bundledDylib: String? {
    Bundle.main.resourceURL?.appendingPathComponent(dylibName).path
}

/// An `LSUIElement` app that fails at load has no window to complain in and
/// would just vanish, so say it out loud.
private func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Kweku: \(message)\n".utf8))
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Kweku can’t start"
    alert.informativeText = message
    alert.runModal()
    exit(1)
}

let candidates = [developmentDylib, bundledDylib].compactMap { $0 }

guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
    die("""
        \(dylibName) isn’t installed. Looked in:

        \(candidates.joined(separator: "\n"))

        Run `make app` in the notch repo to build it.
        """)
}

guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
    let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
    die("couldn’t load \(path)\n\n\(reason)")
}

guard let entry = dlsym(handle, "KwekuMain") else {
    die("\(path) has no KwekuMain entry point — it’s from an older build. Run `make app`.")
}

typealias KwekuMain = @convention(c) () -> Int32
exit(unsafeBitCast(entry, to: KwekuMain.self)())
