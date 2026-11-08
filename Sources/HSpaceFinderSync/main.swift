import Foundation

// An app extension's executable hands control to the extension runtime, which loads the principal class named in
// the bundle's Info.plist (Support/Extensions/FinderSync/Info.plist). SwiftPM has no app extension target, so this is
// a plain executable that scripts/build-app.sh wraps into HSpaceFinderSync.appex.
@_silgen_name("NSExtensionMain")
func extensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

exit(extensionMain(CommandLine.argc, CommandLine.unsafeArgv))
