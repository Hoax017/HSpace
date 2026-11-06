import Foundation
import HSpaceContracts

// SidebarColors pod's sole public contract surface (Axiom 3): the colours the owner gave sidebar items, and the palette
// that colours the rest. Colours are names: the app maps them to system colours, so light and dark both work and no hex exists.

public struct SidebarColorError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    /// What `localizedDescription` gives on `any Error`, which is how the app receives it
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

public enum SidebarColor: String, Sendable, Codable, CaseIterable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray
}

/// A set of colours dealt out to the items of each sidebar group, in turn
public enum SidebarPalette: String, Sendable, Codable, CaseIterable {
    /// No colours: the sidebar's own look
    case standard
    case spectrum, cool, warm, mono

    public var colors: [SidebarColor] {
        switch self {
        case .standard: []
        case .spectrum: [.red, .orange, .yellow, .green, .teal, .blue, .indigo, .purple, .pink]
        case .cool: [.teal, .blue, .indigo, .purple, .mint]
        case .warm: [.red, .orange, .yellow, .pink, .brown]
        case .mono: [.gray]
        }
    }
}

/// Identifies a sidebar item across launches
public enum SidebarItemKey {
    /// A bookmark keeps its colour when its folder moves
    public static func bookmark(_ id: UUID) -> String { "bookmark:\(id.uuidString)" }
    /// Volumes and fixed places have nothing steadier than their path
    public static func place(path: String) -> String { "place:\(path)" }
}

public struct SidebarColorSettings: Sendable, Codable, Equatable {
    public var palette: SidebarPalette
    public var items: [String: SidebarColor]

    public init(palette: SidebarPalette = .standard, items: [String: SidebarColor] = [:]) {
        self.palette = palette
        self.items = items
    }

    /// The item's own colour, otherwise its turn in the palette (`index` is its place in its group). nil keeps the default look.
    public func color(for key: String, index: Int) -> SidebarColor? {
        if let own = items[key] { return own }
        let colors = palette.colors
        guard !colors.isEmpty, index >= 0 else { return nil }
        return colors[index % colors.count]
    }
}

public protocol SidebarColorStoring: Sendable {
    func settings() -> SidebarColorSettings
    /// nil removes the item's own colour
    func setColor(_ color: SidebarColor?, for key: String) throws
    func setPalette(_ palette: SidebarPalette) throws
    func takeProblem() -> SidebarColorError?
}
