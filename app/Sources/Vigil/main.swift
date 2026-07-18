// SwiftPM entry stub — the whole app lives in the VigilApp LIBRARY target so the Xcode
// thin shell (shell/VigilShell.xcodeproj) can link the same body for XCUITest (T2).
// This preserves the plain SwiftPM run path: `swift run Vigil`. The executable is named
// `Vigil` (not `vigil-app`) so the bare-binary App menu reads About/Hide/Quit "Vigil"
// (macOS derives those from the executable filename).
import VigilApp

VigilRootApp.main()
