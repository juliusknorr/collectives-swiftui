import Foundation

public enum PageViewMode: String, CaseIterable, Sendable {
    case view = "preview"
    case edit
    case richText

    public var title: String {
        switch self { case .view: "View"; case .edit: "Edit"; case .richText: "Rich Text" }
    }
}

public struct PageModePreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func modeForPage(canEdit: Bool, hasConflict: Bool) -> PageViewMode {
        let key = defaults.bool(forKey: "rememberPageMode") ? "lastPageMode" : "defaultPageMode"
        let fallback = PageViewMode(rawValue: defaults.string(forKey: "defaultPageMode") ?? "") ?? .view
        let preferred = PageViewMode(rawValue: defaults.string(forKey: key) ?? "") ?? fallback
        if !canEdit { return .view }
        if hasConflict && preferred == .richText { return .edit }
        return preferred
    }
    public func remember(_ mode: PageViewMode) { defaults.set(mode.rawValue, forKey: "lastPageMode") }
}
