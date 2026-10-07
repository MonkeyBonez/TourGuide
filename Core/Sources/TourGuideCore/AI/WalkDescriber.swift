#if canImport(FoundationModels)
import Foundation
import FoundationModels

// Apple's on-device model writes a title and a sentence per walk (PRD §8.13). One fresh session per
// walk: a shared session's transcript is what made the combined run compare "Route 3" with
// "Route 1" and drop a walk (measured 6 Oct 2026). No examples in any guide: the model copies them.

@available(iOS 26, macOS 26, *)
@Generable struct WalkBlurb {
    @Guide(description: "A title of three to six words naming what sets this walk apart. No numbers.")
    var title: String
    @Guide(description: "One or two short sentences on what this walk passes. No numbers.")
    var text: String
}

@available(iOS 26, macOS 26, *)
@Generable struct WalkSentence {
    @Guide(description: "One or two short sentences on what this walk passes. No numbers.")
    var text: String
}

@available(iOS 26, macOS 26, *)
@Generable struct WalkTitle {
    @Guide(description: "A title of two to five words naming what sets this walk apart. No numbers.")
    var title: String
}

@available(iOS 26, macOS 26, *)
@Generable struct GuardedWalkBlurb {
    @Guide(description: "A title of three to six words naming what sets this walk apart.", .pattern(#/[A-Z][A-Za-z ]+/#))
    var title: String
    @Guide(description: "One or two short sentences on what this walk passes. No numbers.")
    var text: String
}

@available(iOS 26, macOS 26, *)
public final class OnDeviceWalkDescriber: @unchecked Sendable {
    public let variant: WalkFacts.Variant
    public let sampling: WalkSampling
    public var maximumResponseTokens = 120

    public init(variant: WalkFacts.Variant, sampling: WalkSampling) {
        self.variant = variant; self.sampling = sampling
    }

    public static var availability: WalkDescriberAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .modelNotReady
        }
    }

    /// Loads the model's assets ahead of the first walk (measured in the harness's first-call column).
    public func prewarm() {
        LanguageModelSession(instructions: WalkFacts.instructions(variant, direct: false)).prewarm()
    }

    var options: GenerationOptions {
        switch sampling {
        case .default: return GenerationOptions(maximumResponseTokens: maximumResponseTokens)
        case .greedy: return GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumResponseTokens)
        case .temperature(let t): return GenerationOptions(temperature: t, maximumResponseTokens: maximumResponseTokens)
        }
    }

    public func describe(_ o: WalkOption, context: WalkFacts.Context) async throws -> WalkBlurbText {
        do { return try await once(o, context: context) }
        catch let e as LanguageModelSession.GenerationError {
            switch e {
            case .rateLimited, .concurrentRequests:
                try await Task.sleep(nanoseconds: 2_000_000_000)
                do { return try await once(o, context: context) }
                catch let e2 as LanguageModelSession.GenerationError { throw Self.map(e2) }
            default: throw Self.map(e)
            }
        }
    }

    func once(_ o: WalkOption, context: WalkFacts.Context) async throws -> WalkBlurbText {
        let session = LanguageModelSession(instructions: WalkFacts.instructions(variant, direct: o.isDirect))
        let prompt = WalkFacts.prompt(for: o, variant: variant, context: context)
        switch variant {
        case .blurbOnly:
            let r = try await session.respond(to: prompt, generating: WalkSentence.self, options: options).content
            return WalkBlurbText(title: WalkFacts.codeTitle(o), text: r.text)
        case .titleOnly, .titleAnchored, .titleTop2:
            let r = try await session.respond(to: prompt, generating: WalkTitle.self, options: options).content
            return WalkBlurbText(title: r.title, text: "")
        case .guarded:
            let r = try await session.respond(to: prompt, generating: GuardedWalkBlurb.self, options: options).content
            return WalkBlurbText(title: r.title, text: r.text)
        default:
            let r = try await session.respond(to: prompt, generating: WalkBlurb.self, options: options).content
            return WalkBlurbText(title: r.title, text: r.text)
        }
    }

    static func map(_ e: LanguageModelSession.GenerationError) -> WalkDescriberError {
        switch e {
        case .guardrailViolation(let c): return .refused(c.debugDescription)
        case .refusal(_, let c): return .refused(c.debugDescription)
        case .unsupportedGuide: return .unsupportedGuide
        case .assetsUnavailable, .unsupportedLanguageOrLocale: return .unavailable
        case .exceededContextWindowSize(let c), .decodingFailure(let c), .rateLimited(let c), .concurrentRequests(let c):
            return .failed(c.debugDescription)
        @unknown default: return .failed("\(e)")
        }
    }
}
#endif
