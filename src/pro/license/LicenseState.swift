enum LicenseState: Equatable {
    case trialNotStarted
    case trial(daysRemaining: Int)
    case pro
    /// A local full-feature build: every Pro feature is unlocked, with no expiry and no purchase.
    /// It is deliberately distinct from `.pro` — nothing was bought and nothing was licensed.
    case local
    case proExpired
    case trialExpired

    var isProAvailable: Bool {
        switch self {
        case .trial, .pro, .local: return true
        case .trialNotStarted, .proExpired, .trialExpired: return false
        }
    }

    /// Fully available without a trial deadline: a currently valid purchased license or a local build.
    var isFullyEntitled: Bool {
        switch self {
        case .pro, .local: return true
        case .trialNotStarted, .trial, .proExpired, .trialExpired: return false
        }
    }

    var debugProfileLabel: String {
        switch self {
        case .trialNotStarted: return "Setup"
        case .trial: return "Trial"
        case .pro: return "Pro"
        case .local: return "Local build"
        case .proExpired, .trialExpired: return "Free"
        }
    }

    /// Setup has no tier yet. The appcast tag distinguishes expired Pro from expired trials;
    /// `debugProfileLabel` and the analytics view group both as Free. A local build reports no
    /// tier either: it is not a purchase, so it must not look like one to the update feed.
    var appcastTier: String {
        switch self {
        case .trialNotStarted: return ""
        case .local: return ""
        case .trial: return "trial"
        case .pro: return "pro"
        case .proExpired: return "proExpired"
        case .trialExpired: return "trialExpired"
        }
    }
}
