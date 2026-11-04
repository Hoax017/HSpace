import Foundation

// PathComplete pod's sole public contract surface (Axiom 3): input prefix → directory completion candidates (pure logic, Oracle needs no file system)

public protocol PathCompleting: Sendable {
    /// Takes any path prefix (supports ~ expansion), returns full path candidates (directories only, with a trailing /)
    func complete(_ input: String) -> [String]
}
