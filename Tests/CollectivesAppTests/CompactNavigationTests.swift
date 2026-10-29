import SwiftUI
import Testing
@testable import CollectivesApp

@Test func compactListsHighlightOnlyWhileTheNextColumnIsPushed() {
    #expect(!CompactNavigation.showsSelection(of: .sidebar, at: .sidebar))
    #expect(CompactNavigation.showsSelection(of: .sidebar, at: .content))
    #expect(CompactNavigation.showsSelection(of: .sidebar, at: .detail))
    #expect(!CompactNavigation.showsSelection(of: .content, at: .sidebar))
    #expect(!CompactNavigation.showsSelection(of: .content, at: .content))
    #expect(CompactNavigation.showsSelection(of: .content, at: .detail))
}
