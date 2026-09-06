import Foundation

/// C entry point that the frozen host binary resolves with `dlsym`.
///
/// The app bundle is signed once and then never rebuilt, so that macOS keeps
/// recognising it as the same app and keeps its TCC grants (see the note at the
/// top of `Sources/Kweku/main.swift`). Everything that changes build to build
/// lives in this library instead, outside the signature seal — so this symbol
/// is the seam between the two.
///
/// Never returns in practice: `KwekuApp.main()` enters the AppKit run loop.
@_cdecl("KwekuMain")
public func KwekuMain() -> Int32 {
    KwekuApp.main()
    return 0
}
