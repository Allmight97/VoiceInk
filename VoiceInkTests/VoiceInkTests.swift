import Testing
@testable import VoiceInk

struct VoiceInkTests {

    @Test("Output filtering removes bracketed transcript artifacts")
    func outputFilteringRemovesBracketedArtifacts() {
        let filtered = TranscriptionOutputFilter.filter("Keep [aside]   this.")

        #expect(filtered == "Keep this.")
    }
}
