import Foundation
import Testing
@testable import CollectivesCore

@Test func pageModesHonorDefaultAndOptionalLastSelection() {
    let name = "PageModes-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = PageModePreferences(defaults: defaults)
    defaults.set("richText", forKey: "defaultPageMode")
    preferences.remember(.edit)
    #expect(preferences.modeForPage(canEdit: true, hasConflict: false) == .richText)
    defaults.set(true, forKey: "rememberPageMode")
    #expect(preferences.modeForPage(canEdit: true, hasConflict: false) == .edit)
    preferences.remember(.richText)
    #expect(preferences.modeForPage(canEdit: false, hasConflict: false) == .view)
    #expect(preferences.modeForPage(canEdit: true, hasConflict: true) == .edit)
    #expect(preferences.modeForPage(canEdit: true, hasConflict: false) == .richText)
    defaults.set(false, forKey: "rememberPageMode")
    defaults.set("preview", forKey: "defaultPageMode")
    #expect(preferences.modeForPage(canEdit: true, hasConflict: false) == .view)
}

@Test func pageModesMigrateExistingAndInvalidPreferences() {
    let name = "PageModes-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = PageModePreferences(defaults: defaults)
    defaults.set("edit", forKey: "defaultPageMode")
    #expect(preferences.modeForPage(canEdit: true, hasConflict: false) == .edit)
    defaults.set(true, forKey: "rememberPageMode")
    defaults.set("invalid", forKey: "lastPageMode")
    #expect(preferences.modeForPage(canEdit: true, hasConflict: false) == .edit)
    defaults.set("invalid", forKey: "defaultPageMode")
    #expect(preferences.modeForPage(canEdit: true, hasConflict: false) == .view)
}

@Test func newPagesOpenForEditingWithoutChangingRememberedMode() {
    let name = "PageModes-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = PageModePreferences(defaults: defaults)
    #expect(preferences.modeForNewPage(canEdit: true) == .edit)
    #expect(preferences.modeForNewPage(canEdit: false) == .view)
    defaults.set("richText", forKey: "defaultPageMode")
    #expect(preferences.modeForNewPage(canEdit: true) == .richText)
    defaults.set(true, forKey: "rememberPageMode")
    preferences.remember(.view)
    #expect(preferences.modeForNewPage(canEdit: true) == .edit)
    #expect(preferences.modeForPage(canEdit: true, hasConflict: false) == .view)
}
