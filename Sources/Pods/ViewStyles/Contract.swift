import Foundation
import HSpaceContracts

// ViewStyles pod's sole public contract surface (Axiom 3): how a folder wants to be shown, and the owner's named styles.
// Values stay raw (Int, String) because the view types live in the app layer. Fields a style does not set are left as they are.

public enum IconLabelPosition: String, Sendable, Codable, CaseIterable {
    case bottom, right
}

/// How the icon view lays out its items
public struct IconLayout: Sendable, Codable, Equatable {
    public static let sizes: ClosedRange<Int> = 32...256
    public static let spacings = [4, 8, 16, 24]
    public static let standard = IconLayout(iconSize: 80, spacing: 8, label: .bottom)
    /// Width kept for the name beside an icon
    public static let sideLabelWidth = 160
    /// Above this, a larger thumbnail is worth generating
    public static let smallThumbnail = 128

    public var iconSize: Int
    public var spacing: Int
    public var label: IconLabelPosition

    /// Out-of-range values, from an old or edited file, land on the nearest allowed one
    public init(iconSize: Int, spacing: Int, label: IconLabelPosition) {
        self.iconSize = min(Self.sizes.upperBound, max(Self.sizes.lowerBound, iconSize))
        self.spacing = Self.spacings.min { abs($0 - spacing) < abs($1 - spacing) } ?? 8
        self.label = label
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(iconSize: try c.decode(Int.self, forKey: .iconSize), spacing: try c.decode(Int.self, forKey: .spacing),
                  label: try c.decode(IconLabelPosition.self, forKey: .label))
    }

    /// One grid cell: room for the icon and its name
    public var itemSize: (width: Int, height: Int) {
        switch label {
        case .bottom: return (iconSize + 32, iconSize + 44)
        case .right: return (iconSize + 12 + Self.sideLabelWidth, max(iconSize + 8, 44))
        }
    }

    /// The thumbnail to request, in points. Two steps only, so resizing does not regenerate at every size.
    public var thumbnailSize: Int { iconSize > Self.smallThumbnail ? Self.sizes.upperBound : Self.smallThumbnail }
}

public struct ViewStyle: Sendable, Codable, Equatable {
    public var viewMode: Int?
    public var sortKey: String?
    public var sortAscending: Bool?
    public var includeHidden: Bool?
    public var iconLayout: IconLayout?

    public init(viewMode: Int? = nil, sortKey: String? = nil, sortAscending: Bool? = nil, includeHidden: Bool? = nil,
                iconLayout: IconLayout? = nil) {
        self.viewMode = viewMode
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.includeHidden = includeHidden
        self.iconLayout = iconLayout
    }
}

public struct SavedViewStyle: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var style: ViewStyle
}

/// A remembered folder
public struct FolderViewRule: Sendable, Codable, Equatable {
    public var style: ViewStyle
    /// Folders below this one follow it too, unless they have a rule of their own
    public var includeSubfolders: Bool

    public init(style: ViewStyle, includeSubfolders: Bool = false) {
        self.style = style
        self.includeSubfolders = includeSubfolders
    }
}

/// The rule in force for a folder
public struct ResolvedViewRule: Sendable, Equatable {
    public let rule: FolderViewRule
    /// The remembered folder it came from
    public let folder: String
    /// False when it is inherited from a parent
    public let isExact: Bool
}

public struct ViewStyleError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

public protocol ViewStyleStoring: Sendable {
    /// The rule for a folder: its own, or the nearest parent's that includes subfolders
    func rule(for path: String) -> ResolvedViewRule?
    func folders() -> [String: FolderViewRule]
    func styles() -> [SavedViewStyle]
    func setRule(_ rule: FolderViewRule, for path: String) throws
    func removeRule(for path: String) throws
    /// A blank name, or one already in use whatever its case, is refused
    func saveStyle(named name: String, style: ViewStyle) throws -> SavedViewStyle
    func renameStyle(_ id: UUID, to name: String) throws
    func deleteStyle(_ id: UUID) throws
    /// Hands over, once, a failure at load that no call could throw
    func takeProblem() -> ViewStyleError?
}
