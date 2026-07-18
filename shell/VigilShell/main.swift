// Xcode thin shell (T2): the ENTIRE app lives in the SwiftPM
// package (app/, product "VigilApp"); this target contributes nothing but the .app
// bundle + entry point so XCUITest can host and drive the real UI.
import VigilApp

VigilRootApp.main()
