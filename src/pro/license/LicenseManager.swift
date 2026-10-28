import Foundation

class LicenseManager {
    /// Build channel: a local full-feature build (compiled with `LOCAL_FULL_FEATURES`) unlocks every
    /// Pro feature without a purchase. It is a build-time fact, not a runtime state: the official
    /// release never defines the flag and therefore never behaves like a local build.
    static let isLocalBuild: Bool = {
        #if LOCAL_FULL_FEATURES
        return true
        #else
        return false
        #endif
    }()

    static var keychainService: String {
        #if DEBUG
        if QaLifecycleEnvironment.enabled { return QaLifecycleEnvironment.namespace }
        #endif
        return "\(App.bundleIdentifier).license"
    }
    static var defaultsSuiteName: String {
        #if DEBUG
        if QaLifecycleEnvironment.enabled { return QaLifecycleEnvironment.namespace }
        #endif
        return "\(App.bundleIdentifier).license"
    }

    static let shared: LicenseManager = {
        // A local build must never share the released app's license storage. The local build ships
        // with an isolated `.developer` bundle identifier; running under the official one would
        // silently inherit the user's real Keychain service and license defaults, so refuse to start.
        if isLocalBuild {
            precondition(App.bundleIdentifier != "com.lwouis.alt-tab-macos",
                         "A local full-feature build must not run under the official bundle identifier.")
        }
        let keychain = SystemKeychain(service: keychainService)
        return LicenseManager(
            clock: SystemClock(),
            keychain: keychain,
            api: RemoteLicenseClient(baseUrl: Endpoints.licenseApiBaseUrl, keychain: keychain),
            defaults: UserDefaults(suiteName: defaultsSuiteName)!,
            localFeaturesEnabled: isLocalBuild
        )
    }()

    static let trialDuration = 14
    private static let revalidationInterval: TimeInterval = 30 * 24 * 60 * 60 // 30 days
    static let keychainKeyAccount = "licenseKey"
    static let keychainInstanceAccount = "instanceId"
    static let keychainVariantAccount = "variantId"
    static let customerEmailKey = "customerEmail"
    /// Variant slugs that grant a Lifetime license (no version cutoff, ever).
    /// Everything else is regular Pro and may appear in `versionLimitedVariants`.
    static let lifetimeVariants: Set<String> = ["pro_lifetime"]
    /// Maps version-limited variant slugs to their max supported version.
    /// When a Pro variant needs a cutoff, add: "variant_slug": "X.Y.Z".
    static let versionLimitedVariants: [String: String] = [:]

    let clock: Clock
    let keychain: Keychain
    let api: LicenseAPI
    let defaults: UserDefaults

    /// True when this manager runs in a local full-feature build: every Pro feature is unlocked
    /// without a purchase, a license key or a trial. Injected so tests can exercise the local
    /// contract without the compile-time flag.
    let localFeaturesEnabled: Bool

    /// Called whenever `state` changes (including the initial `initialize()` assignment).
    /// Production wires this up in App.swift to refresh Menubar, sync Sparkle cookie, and notify ProTransitionManager.
    /// Tests leave it unset to avoid side effects.
    var onStateChanged: ((LicenseState) -> Void)?

    /// Provides the current app version for version-limited variant checks. Defaults to the bundle's version;
    /// tests override to simulate upgrades across cutoffs.
    var currentAppVersion: () -> String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Invoked before a license activation flips `state` to `.pro` so any Pro selections that were
    /// snapshotted when Pro locked can be restored. Wired at app startup; no-op by default so tests
    /// can drive activation without side effects.
    var onBeforeProUnlock: () -> Void = { }

    private var appIsUsable = false

    private(set) var state: LicenseState {
        didSet { onStateChanged?(state) }
    }

    #if DEBUG
    private var hasMockedLicense = false
    private var mockedTrialStartDate: Date?
    private var mockedCustomerEmail: String?
    private var mockedVariant: String?
    #endif

    var customerEmail: String? {
        if localFeaturesEnabled { return nil }
        #if DEBUG
        if hasMockedLicense { return mockedCustomerEmail }
        #endif
        return defaults.string(forKey: Self.customerEmailKey)
    }

    var isLifetimeVariant: Bool {
        if localFeaturesEnabled { return false }
        #if DEBUG
        if hasMockedLicense { return mockedVariant.map(Self.lifetimeVariants.contains) ?? false }
        #endif
        guard let variant = keychain.value(account: Self.keychainVariantAccount) else { return false }
        return Self.lifetimeVariants.contains(variant)
    }

    var isProAvailable: Bool { state.isProAvailable }

    var isMocked: Bool {
        #if DEBUG
        return hasMockedLicense
        #else
        return false
        #endif
    }

    /// Pro features are locked out as soon as the license is no longer valid. Degradable Pro
    /// preferences are downgraded to their Free equivalents immediately via
    /// `ProTransitionManager.onProLockEngaged()`, wired to the state-change hook in App.swift.
    var isProLocked: Bool {
        switch state {
        case .trialNotStarted, .pro, .trial, .local: return false
        case .proExpired, .trialExpired: return true
        }
    }

    var trialStartDate: Date? {
        if localFeaturesEnabled { return nil }
        #if DEBUG
        if hasMockedLicense { return mockedTrialStartDate }
        #endif
        guard defaults.object(forKey: "trialStartDate") != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: "trialStartDate"))
    }

    var daysSinceTrialStart: Int {
        guard let start = trialStartDate else { return 0 }
        return Int(clock.now.timeIntervalSince(start) / 86400)
    }

    /// 1-indexed, like the "Day N" of `ProTransitionSpecs.md`. Nil when no trial ever started, or when the clock
    /// is set before the trial start, rather than a made-up day.
    var trialDay: Int? {
        guard let start = trialStartDate, clock.now >= start else { return nil }
        return daysSinceTrialStart + 1
    }

    var trialEndDate: Date? {
        trialStartDate?.addingTimeInterval(Double(Self.trialDuration) * 86400)
    }

    /// `state` only follows the clock when something calls `refreshState()`, so an app left running keeps a
    /// `.trial` state past the trial's end. Cheap: no Keychain read.
    var trialEndedSinceLastRefresh: Bool {
        guard case .trial = state, let trialEndDate else { return false }
        return clock.now >= trialEndDate
    }

    init(clock: Clock, keychain: Keychain, api: LicenseAPI, defaults: UserDefaults,
         localFeaturesEnabled: Bool = LicenseManager.isLocalBuild) {
        self.clock = clock
        self.keychain = keychain
        self.api = api
        self.defaults = defaults
        self.localFeaturesEnabled = localFeaturesEnabled
        // A local full-feature build is entitled from the start: no setup, no trial, no purchase.
        self.state = localFeaturesEnabled ? .local : .trialNotStarted
    }

    func initialize() {
        state = computeState()
        scheduleAsyncRevalidationIfNeeded()
    }

    /// Trial `daysRemaining` is baked into the `state` enum, so it stays frozen until something
    /// reassigns `state`. Call this from UI surfaces before they read `state` so the day count
    /// reflects the current clock. `didSet` only fires when the value actually changed.
    func refreshState() {
        let newState = computeState()
        if newState != state { state = newState }
    }

    /// Called after the switcher and input handlers exist, with the permission gate still satisfied.
    /// Reads and refreshes never start a trial; a saved start is immutable even after revocation or expiry.
    func onAppBecameUsable(accessibility: PermissionStatus, screenRecording: PermissionStatus) {
        guard PermissionFlow.isComplete(accessibility: accessibility, screenRecording: screenRecording) else { return }
        appIsUsable = true
        startTrialIfNeeded()
    }

    private func startTrialIfNeeded() {
        guard !localFeaturesEnabled else { return }
        guard appIsUsable, !isMocked, defaults.object(forKey: "trialStartDate") == nil,
              keychain.value(account: Self.keychainKeyAccount) == nil else { return }
        defaults.set(clock.now.timeIntervalSince1970, forKey: "trialStartDate")
        refreshState()
    }

    var onActivationSucceeded: () -> Void = {}

    func activate(_ licenseKey: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // A local build is already fully entitled and has no license to buy: no API call, no Keychain
        // write, and an explicit error rather than a fake activation success.
        guard !localFeaturesEnabled else {
            completion(.failure(LicenseAPIError.localBuild))
            return
        }
        api.activate(licenseKey) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let response):
                    var writes: [(String, String)] = [
                        (Self.keychainKeyAccount, licenseKey),
                        (Self.keychainInstanceAccount, response.instanceId),
                    ]
                    if let variantId = response.variantId {
                        writes.append((Self.keychainVariantAccount, variantId))
                    }
                    var written: [String] = []
                    for (account, value) in writes {
                        let status = self.keychain.setValue(value, account: account)
                        if status != errSecSuccess {
                            // Only roll back what this activation actually wrote. A failed write left the
                            // previous value in place, so removing that account would delete a license we
                            // never wrote, which is the exact loss `setValue` avoids by not deleting.
                            written.forEach { self.keychain.remove(account: $0) }
                            completion(.failure(LicenseAPIError.keychainWriteFailed(account: account, status: status)))
                            return
                        }
                        written.append(account)
                    }
                    self.defaults.set(self.clock.now.timeIntervalSince1970, forKey: "lastValidation")
                    self.defaults.set(true, forKey: "lastValidationResult")
                    if let email = response.customerEmail, !email.isEmpty {
                        self.defaults.set(email, forKey: Self.customerEmailKey)
                    }
                    self.onBeforeProUnlock()
                    let newlyActivated = self.state != .pro
                    self.state = .pro
                    if newlyActivated { self.onActivationSucceeded() }
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    func deactivate(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !localFeaturesEnabled else {
            completion(.failure(LicenseAPIError.localBuild))
            return
        }
        guard let licenseKey = keychain.value(account: Self.keychainKeyAccount),
              let instanceId = keychain.value(account: Self.keychainInstanceAccount) else {
            completion(.failure(LicenseAPIError.invalidKey))
            return
        }
        api.deactivate(licenseKey, instanceId: instanceId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.keychain.remove(account: Self.keychainKeyAccount)
                    self.keychain.remove(account: Self.keychainInstanceAccount)
                    self.keychain.remove(account: Self.keychainVariantAccount)
                    self.defaults.removeObject(forKey: "lastValidation")
                    self.defaults.removeObject(forKey: "lastValidationResult")
                    self.defaults.removeObject(forKey: Self.customerEmailKey)
                    self.startTrialIfNeeded()
                    self.refreshState()
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    /// Remote-deactivate a specific instance that isn't this machine — used to reclaim a seat
    /// before re-running activation. Does not touch local keychain/UserDefaults state.
    func deactivateInstance(licenseKey: String, instanceId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !localFeaturesEnabled else {
            completion(.failure(LicenseAPIError.localBuild))
            return
        }
        api.deactivate(licenseKey, instanceId: instanceId) { result in
            DispatchQueue.main.async { completion(result) }
        }
    }

    func computeState() -> LicenseState {
        // A local build ignores any persisted license or trial: it is entitled from the start, and
        // it must not read the Keychain or the license defaults to decide that.
        if localFeaturesEnabled { return .local }
        #if DEBUG
        if hasMockedLicense { return mockedTrialStartDate.map(trialState) ?? state }
        #endif
        if keychain.value(account: Self.keychainKeyAccount) != nil {
            let lastValidationResult = defaults.bool(forKey: "lastValidationResult")
            guard lastValidationResult else { return .trialExpired }
            if let variant = keychain.value(account: Self.keychainVariantAccount),
               let maxVersion = Self.versionLimitedVariants[variant] {
                let currentVersion = currentAppVersion()
                if currentVersion.compare(maxVersion, options: .numeric) == .orderedDescending {
                    return .proExpired
                }
            }
            return .pro
        }
        return computeTrialState()
    }

    private func computeTrialState() -> LicenseState {
        guard let start = trialStartDate else { return .trialNotStarted }
        return trialState(start)
    }

    private func trialState(_ trialStart: Date) -> LicenseState {
        let daysSinceTrialStart = Int(clock.now.timeIntervalSince(trialStart) / (24 * 60 * 60))
        guard daysSinceTrialStart < Self.trialDuration else { return .trialExpired }
        return .trial(daysRemaining: Self.trialDuration - daysSinceTrialStart)
    }

    func scheduleAsyncRevalidationIfNeeded() {
        // A local build has no license to revalidate: no Keychain read, no request.
        guard !localFeaturesEnabled else { return }
        let lastValidation = defaults.double(forKey: "lastValidation")
        let elapsed = clock.now.timeIntervalSince1970 - lastValidation
        guard elapsed >= Self.revalidationInterval else { return }
        revalidateWithServer()
    }

    func revalidateWithServer() {
        guard !localFeaturesEnabled else { return }
        guard let licenseKey = keychain.value(account: Self.keychainKeyAccount),
              let instanceId = keychain.value(account: Self.keychainInstanceAccount) else { return }
        api.validate(licenseKey, instanceId: instanceId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let response):
                    self.defaults.set(self.clock.now.timeIntervalSince1970, forKey: "lastValidation")
                    self.defaults.set(response.valid, forKey: "lastValidationResult")
                    if let variantId = response.variantId {
                        self.keychain.setValue(variantId, account: Self.keychainVariantAccount)
                    }
                    if response.valid {
                        self.state = self.computeState()
                    } else {
                        self.state = .trialExpired
                    }
                case .failure:
                    break // network error: do nothing, try again next launch
                }
            }
        }
    }

    #if DEBUG
    /// `day` is 1-based: day 1 is the day the trial started. The mocked trial then follows `clock` on
    /// `refreshState()`, like a real one.
    func mockTrialDay(_ day: Int) {
        // A local build is already fully entitled: a QA overlay must not put it on a trial clock.
        guard !localFeaturesEnabled else { return }
        hasMockedLicense = true
        mockedTrialStartDate = clock.now.addingTimeInterval(-Double(day - 1) * 86400)
        mockedCustomerEmail = nil
        mockedVariant = nil
        state = trialState(mockedTrialStartDate!)
    }

    func mockProUser() {
        // A local build is not a purchase: QA must not claim one either.
        guard !localFeaturesEnabled else { return }
        hasMockedLicense = true
        mockedTrialStartDate = nil
        mockedCustomerEmail = "john@cool-software.com"
        mockedVariant = "pro"
        onBeforeProUnlock()
        state = .pro
    }
    #endif
}
