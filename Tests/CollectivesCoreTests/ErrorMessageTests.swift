import Foundation
import Testing
import CollectivesCore

@Test func httpStatusCodesMapToPlainLanguage() {
    #expect(CollectivesError.http(401).localizedDescription.contains("Sign in again"))
    #expect(CollectivesError.http(403).localizedDescription.contains("permission"))
    #expect(CollectivesError.http(404).localizedDescription.contains("not found"))
    #expect(CollectivesError.http(503).localizedDescription == "Nextcloud is unavailable right now. Try again later.")
    #expect(CollectivesError.http(500).localizedDescription == CollectivesError.http(503).localizedDescription)
    #expect(CollectivesError.http(418).localizedDescription.contains("418"))
    #expect(!CollectivesError.http(503).localizedDescription.contains("HTTP"))
}

@Test func networkFailuresMapToOfflineAndUnreachableCopy() {
    #expect(CollectivesError.userMessage(for: URLError(.notConnectedToInternet)).hasPrefix("You’re offline"))
    #expect(CollectivesError.userMessage(for: URLError(.cannotConnectToHost)).hasPrefix("Can’t reach the server"))
    #expect(CollectivesError.userMessage(for: URLError(.timedOut)).hasPrefix("Can’t reach the server"))
    #expect(CollectivesError.userMessage(for: CollectivesError.http(403)) == CollectivesError.http(403).localizedDescription)
}

@Test func localErrorsExplainWhatToDoInsteadOfBlamingTheServer() {
    let local: [CollectivesError] = [.noAccount, .signInRequired, .busy, .richTextOpenElsewhere, .draftNotSaved]
    let serverCopy = CollectivesError.invalidResponse.localizedDescription
    for error in local {
        #expect(error.localizedDescription != serverCopy)
        #expect(!error.localizedDescription.contains("server returned"))
    }
    #expect(Set(local.map(\.localizedDescription)).count == local.count)
    #expect(CollectivesError.signInRequired.requiresSignIn)
    #expect(CollectivesError.http(401).requiresSignIn)
    #expect(!CollectivesError.busy.requiresSignIn)
    #expect(CollectivesError.requiresSignIn(CollectivesError.signInRequired))
    #expect(!CollectivesError.requiresSignIn(URLError(.timedOut)))
}
