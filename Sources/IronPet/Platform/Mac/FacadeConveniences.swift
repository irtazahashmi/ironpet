import Foundation

// Convenience initialisers for code that builds a facade over the Mac's own service: Settings and previews rendered without the
// app, and tests. The facades take protocols, so these keep the concrete types out of their files.

extension VoiceAPI {
    /// A voice API with its own speaker, for Settings rendered without the app, so Preview still has something to play through.
    static func standalone(settings: SettingsAPI) -> VoiceAPI {
        let api = VoiceAPI(speech: SpeechPlayer(), settings: settings)
        api.transcoder = MacAudioTranscoder()
        return api
    }
}

extension ScreenAPI {
    convenience init(service: CaptureService) { self.init(control: service) }
}

extension PetAPI {
    /// A pet API over the app's own pet and background folders, for the Settings pages until `IronPetAPI` sets its own.
    static func onThisMac() -> PetAPI { PetAPI(settings: .live, assets: MacPetAssets()) }
}
