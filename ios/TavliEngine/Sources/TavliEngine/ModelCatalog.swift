import CoreML
import Foundation

/// Where each variant's Core ML value model lives (#143), and whether it is there at
/// all. Every variant names its model via `GameVariant.modelResourceName`
/// (`PlakotoValue`, `PlakotoStandardValue`, `FevgaValue`, `PortesValue`); a model that
/// is not bundled means **no AI for that variant** — the app shows it as "Computer
/// not available yet" for vs-AI play instead of silently playing random moves. Dropping
/// the `.mlpackage` into the app's resources is all it takes to enable it.
public struct ModelCatalog: Sendable {
    private let locate: @Sendable (_ name: String, _ ext: String) -> URL?

    /// A catalog over an arbitrary lookup (tests).
    public init(locate: @escaping @Sendable (_ name: String, _ ext: String) -> URL?) {
        self.locate = locate
    }

    /// Models in a bundle's resources (the app: `Bundle.main`).
    public init(bundle: Bundle) {
        let url = bundle.bundleURL
        self.init { name, ext in Bundle(url: url)?.url(forResource: name, withExtension: ext) }
    }

    /// Models in a plain directory (`<dir>/<name>.<ext>`).
    public init(directory: URL) {
        self.init { name, ext in
            let u = directory.appendingPathComponent("\(name).\(ext)")
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
    }

    /// The app bundle's models.
    public static let main = ModelCatalog(bundle: .main)

    /// The bundled model for `variant`: a pre-compiled `.mlmodelc` if present, else the
    /// `.mlpackage` (compiled at load), else `nil`.
    public func modelURL(for variant: any GameVariant) -> URL? {
        let name = variant.modelResourceName
        return locate(name, "mlmodelc") ?? locate(name, "mlpackage")
    }

    /// Whether `variant` has a bundled model, i.e. can be played against the AI.
    public func isAvailable(_ variant: any GameVariant) -> Bool {
        modelURL(for: variant) != nil
    }

    /// The registered variants that can be played against the AI.
    public var availableVariantIDs: [String] {
        GameVariants.all.filter(isAvailable).map(\.id)
    }

    /// Load `config.variant`'s model and wrap it in an `Agent`, or `nil` when the model
    /// is missing or fails to load.
    public func makeAgent(config: GameConfig = .standard) -> Agent? {
        guard let url = modelURL(for: config.variant) else { return nil }
        let compiled: URL?
        if url.pathExtension == "mlmodelc" {
            compiled = url
        } else {
            compiled = try? MLModel.compileModel(at: url)
        }
        guard let compiled, let model = try? MLModel(contentsOf: compiled) else { return nil }
        return Agent(model: model, config: config)
    }
}

/// The persisted variant choice (#143) and the House rules switch (#258).
///
/// **Since #258** the picker offers **Plakoto · Portes · Fevga**, where Plakoto means the
/// standard rules (`plakoto_standard`); the family's house rules (`plakoto`) are no
/// longer a picker entry but a separate switch (`houseRulesKey`, default **off**). The
/// stored choice (`key`) is therefore one of `choiceIDs`; the rules a new game is played
/// under come from both (`playedVariantID(choiceID:houseRules:)`): the switch turns
/// every Plakoto game — single, best-of-three, the Plakoto leg of Full Tavli, vs the
/// computer and two players — into house Plakoto and leaves Portes / Fevga alone.
///
/// A stored house `plakoto` choice (any build before #258) is rewritten once at launch
/// to Plakoto with the switch **off** (`migrate`); `choiceID(forStored:)` reads it the
/// same way in case the migration has not run. Unknown or missing ids (a fresh install,
/// a value from a newer build) fall back to Plakoto.
public enum VariantPreference {
    public static let key = "settings.variant"
    /// The House rules switch (#258): `Bool`, absent = off.
    public static let houseRulesKey = "settings.houseRules"

    /// The picker's choices, in order: Plakoto (standard rules), Portes, Fevga.
    public static let choiceIDs = [GameVariants.plakotoStandard.id, GameVariants.portes.id,
                                   GameVariants.fevga.id]

    /// Whether `variantID` is either Plakoto rule set (the only game with house rules).
    public static func isPlakoto(_ variantID: String) -> Bool {
        variantID == GameVariants.plakoto.id || variantID == GameVariants.plakotoStandard.id
    }

    /// The picker choice for a stored id: house `plakoto` reads as Plakoto (the switch
    /// carries the house rules now), an unknown or missing id as Plakoto.
    public static func choiceID(forStored id: String?) -> String {
        guard let id, GameVariants.variant(forID: id) != nil else { return GameVariants.plakotoStandard.id }
        return id == GameVariants.plakoto.id ? GameVariants.plakotoStandard.id : id
    }

    /// The rules a new game of `choiceID` is played under: house Plakoto for a Plakoto
    /// choice with the switch on, otherwise the choice itself (normalized).
    public static func playedVariantID(choiceID: String, houseRules: Bool) -> String {
        let choice = Self.choiceID(forStored: choiceID)
        guard isPlakoto(choice) else { return choice }
        return houseRules ? GameVariants.plakoto.id : GameVariants.plakotoStandard.id
    }

    /// The picker choice as stored (normalized by `choiceID(forStored:)`).
    public static func loadChoice(from defaults: UserDefaults = .standard) -> any GameVariant {
        GameVariants.variant(forID: choiceID(forStored: defaults.string(forKey: key)))
            ?? GameVariants.plakotoStandard
    }

    /// Whether the House rules switch is on (default off).
    public static func houseRules(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: houseRulesKey) as? Bool ?? false
    }

    public static func setHouseRules(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: houseRulesKey)
    }

    /// The rules new games are played under: the stored choice with the switch applied.
    public static func load(from defaults: UserDefaults = .standard) -> any GameVariant {
        let id = playedVariantID(choiceID: choiceID(forStored: defaults.string(forKey: key)),
                                 houseRules: houseRules(from: defaults))
        return GameVariants.variant(forID: id) ?? GameVariants.plakotoStandard
    }

    /// Store the picker choice for `variant`; house Plakoto is stored as Plakoto (the
    /// switch is set separately, `setHouseRules`).
    public static func save(_ variant: any GameVariant, to defaults: UserDefaults = .standard) {
        defaults.set(choiceID(forStored: variant.id), forKey: key)
    }

    /// One-time rewrite of a pre-#258 preference, run at launch: a stored house
    /// `plakoto` becomes Plakoto with the switch **off** (house rules are opt-in for
    /// everyone, existing installs included). Idempotent — later builds never store
    /// `plakoto` as the choice. Returns whether anything was rewritten.
    @discardableResult
    public static func migrate(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.string(forKey: key) == GameVariants.plakoto.id else { return false }
        defaults.set(GameVariants.plakotoStandard.id, forKey: key)
        if defaults.object(forKey: houseRulesKey) == nil { setHouseRules(false, to: defaults) }
        return true
    }
}
