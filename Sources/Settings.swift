import SwiftUI
import Security
import AVFoundation

// MARK: - Look & feel

/// Darkroom palette: black viewfinder, amber guide light, green for "ready",
/// warm paper-white text, and a serif "notebook" voice for anything the AI says.
enum Theme {
    static let amber = Color(red: 0.96, green: 0.72, blue: 0.25)
    static let go = Color(red: 0.56, green: 0.88, blue: 0.54)
    static let paper = Color(red: 0.95, green: 0.93, blue: 0.89)
    static let muted = Color(red: 0.60, green: 0.58, blue: 0.54)
    static let panel = Color(red: 0.11, green: 0.10, blue: 0.094)
    static let well = Color.white.opacity(0.08)

    /// The AI's voice.
    static func note(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif).italic() }
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight) }
}

// MARK: - Shooting options

/// Photo shape. Flips automatically when the phone is held sideways (4:5 -> 5:4).
enum ShotAspect: String, CaseIterable, Identifiable {
    case fourFive = "4:5"
    case square = "1:1"
    case threeFour = "3:4"
    case nineSixteen = "9:16"

    var id: String { rawValue }

    /// Short side / long side.
    var shortOverLong: Double {
        switch self {
        case .fourFive: return 0.8
        case .square: return 1.0
        case .threeFour: return 0.75
        case .nineSixteen: return 0.5625
        }
    }

    func label(landscape: Bool) -> String {
        guard landscape else { return rawValue }
        let parts = rawValue.split(separator: ":")
        return parts.count == 2 ? "\(parts[1]):\(parts[0])" : rawValue
    }

    /// Photo width / height.
    func wOverH(landscape: Bool) -> Double {
        landscape ? 1 / shortOverLong : shortOverLong
    }

    var next: ShotAspect {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }

    static var current: ShotAspect {
        ShotAspect(rawValue: UserDefaults.standard.string(forKey: "aspect") ?? "") ?? .fourFive
    }
}

enum FlashSetting: String, CaseIterable {
    case off, auto, on

    var next: FlashSetting {
        switch self {
        case .off: return .auto
        case .auto: return .on
        case .on: return .off
        }
    }

    var icon: String {
        switch self {
        case .off: return "bolt.slash"
        case .auto: return "bolt.badge.a"
        case .on: return "bolt.fill"
        }
    }

    var mode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: return .off
        case .auto: return .auto
        case .on: return .on
        }
    }

    static var current: FlashSetting {
        FlashSetting(rawValue: UserDefaults.standard.string(forKey: "flash") ?? "") ?? .off
    }
}

/// What the AI should look for when it scans.
enum ShotStyle: String, CaseIterable, Identifiable {
    case anything, cozy, minimal, nature, architecture, street, food, people

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anything: return "Anything good"
        case .cozy: return "Cozy and warm"
        case .minimal: return "Clean and minimal"
        case .nature: return "Plants and nature"
        case .architecture: return "Architecture and lines"
        case .street: return "Street and everyday"
        case .food: return "Food and drinks"
        case .people: return "People and pets"
        }
    }

    var promptLine: String {
        switch self {
        case .anything: return ""
        case .cozy: return "The photographer wants cozy, warm, intimate shots: lamps, candles, soft light, textiles."
        case .minimal: return "The photographer wants clean, minimal shots: one simple subject, lots of empty space, clean lines."
        case .nature: return "The photographer wants plants, flowers, trees, sky and natural textures."
        case .architecture: return "The photographer wants architecture, geometry, lines, symmetry and interesting structures."
        case .street: return "The photographer wants everyday street-photo moments, signs, shadows and textures."
        case .food: return "The photographer wants food and drink shots: plates, cups, glasses, ingredients."
        case .people: return "The photographer wants people or pets as the subject, framed flatteringly."
        }
    }

    static var current: ShotStyle {
        ShotStyle(rawValue: UserDefaults.standard.string(forKey: "style") ?? "") ?? .anything
    }
}

// MARK: - AI models

enum AIModel: String, CaseIterable, Identifiable {
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    case opus = "claude-opus-5-5"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sonnet: return "Sonnet 5.5"
        case .haiku: return "Haiku 5.5"
        case .opus: return "Opus 5.5"
        }
    }

    var note: String {
        switch self {
        case .sonnet: return "best balance"
        case .haiku: return "fastest, about 20x cheaper"
        case .opus: return "smartest, slower, 2x the price"
        }
    }
}

/// Vision models on OpenRouter that work for scanning and editing.
struct ORModel: Identifiable {
    let id: String
    let name: String
    let note: String

    static let list: [ORModel] = [
        ORModel(id: "anthropic/claude-sonnet-5.5", name: "Claude Sonnet 5.5", note: "best balance"),
        ORModel(id: "anthropic/claude-haiku-5.5", name: "Claude Haiku 5.5", note: "fastest, about 20x cheaper"),
        ORModel(id: "anthropic/claude-opus-5.5", name: "Claude Opus 5.5", note: "smartest, slower, 2x the price"),
        ORModel(id: "openai/gpt-6-sol", name: "GPT-6 Sol", note: "strong all-rounder"),
        ORModel(id: "openai/gpt-6-luna", name: "GPT-6 Luna", note: "very cheap"),
        ORModel(id: "x-ai/grok-4.7", name: "Grok 4.7", note: "a different eye"),
        ORModel(id: "qwen/qwen3.8-omni-flash", name: "Qwen 3.8 Omni Flash", note: "very cheap"),
        ORModel(id: "mistralai/mistral-large-4-0", name: "Mistral Large 4", note: "cheap"),
        ORModel(id: "z-ai/glm-5.3-flashx", name: "GLM 5.3 FlashX", note: "cheap")
    ]
}

/// Which key and model the app uses right now.
enum AIConfig {
    static var key: String {
        KeyStore.load().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var modelID: String {
        let k = key
        if AIScout.isOpenRouter(k) {
            let custom = (UserDefaults.standard.string(forKey: "customModel") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty { return custom }
            return UserDefaults.standard.string(forKey: "orModel") ?? ORModel.list[0].id
        }
        return (AIModel(rawValue: UserDefaults.standard.string(forKey: "aiModel") ?? "") ?? .sonnet).rawValue
    }

    static var ideasPerScan: Int {
        let n = UserDefaults.standard.integer(forKey: "ideasPerScan")
        return n == 0 ? 3 : min(max(n, 1), 3)
    }
}

/// Keeps the API key on the phone only (Keychain, with a fallback for re-signed apps).
enum KeyStore {
    private static let service = "com.artis.aimshot"
    private static let account = "anthropic-api-key"
    private static let fallbackKey = "apiKeyFallback"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }
        return UserDefaults.standard.string(forKey: fallbackKey) ?? ""
    }

    static func save(_ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey)

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(trimmed, forKey: fallbackKey)
        }
    }
}

// MARK: - Settings screen

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key: String = KeyStore.load()
    @AppStorage("aiModel") private var model: String = AIModel.sonnet.rawValue
    @AppStorage("orModel") private var orModel: String = ORModel.list[0].id
    @AppStorage("customModel") private var customModel: String = ""
    @AppStorage("style") private var style: String = ShotStyle.anything.rawValue
    @AppStorage("ideasPerScan") private var ideasPerScan: Int = 3
    @AppStorage("autoShoot") private var autoShoot: Bool = true
    @AppStorage("autoScan") private var autoScan: Bool = false
    @AppStorage("aiEditNew") private var aiEditNew: Bool = false
    @AppStorage("refine") private var refine: Bool = true
    @AppStorage("matchLook") private var matchLook: Bool = false
    @AppStorage("startLens") private var startLens: String = "wide"
    @AppStorage("showGrid") private var showGrid: Bool = true
    @AppStorage("showLevel") private var showLevel: Bool = true
    @AppStorage("haptics") private var haptics: Bool = true
    @State private var defaultLookName: String = SettingsView.describeDefault()
    @State private var testing = false
    @State private var testResult: String? = nil

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var usingOpenRouter: Bool { AIScout.isOpenRouter(trimmedKey) }

    private static func describeDefault() -> String {
        let d = EditSettings.forNewShots
        if d.isPlain { return "None" }
        var parts: [String] = []
        if d.look != "none" { parts.append(FilmLab.look(d.look).name) }
        if d.frame != .none { parts.append(d.frame.label + " frame") }
        if d.dateStamp { parts.append("date stamp") }
        return parts.isEmpty ? "Custom" : parts.joined(separator: ", ")
    }

    private var keyStatus: String {
        if trimmedKey.isEmpty {
            return "Without a key, Scan uses a basic on-device guess. Paste a Claude key (platform.claude.com) or an OpenRouter key (openrouter.ai/keys)."
        }
        return usingOpenRouter
            ? "OpenRouter key. Uses your OpenRouter credits and stays on this phone."
            : "Claude key. Uses your Anthropic credits and stays on this phone."
    }

    var body: some View {
        NavigationStack {
            Form {
                // AI
                Section {
                    SecureField("sk-ant-… or sk-or-…", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste from clipboard") {
                        if let s = UIPasteboard.general.string { key = s }
                    }
                } header: {
                    Text("API key")
                } footer: {
                    Text(keyStatus)
                }

                Section {
                    if usingOpenRouter {
                        Picker("Model", selection: $orModel) {
                            ForEach(ORModel.list) { m in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name)
                                    Text(m.note).font(.caption).foregroundColor(.secondary)
                                }
                                .tag(m.id)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        TextField("Other model id, e.g. openai/gpt-6-sol", text: $customModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote)
                    } else {
                        Picker("Model", selection: $model) {
                            ForEach(AIModel.allCases) { m in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.label)
                                    Text(m.note).font(.caption).foregroundColor(.secondary)
                                }
                                .tag(m.rawValue)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    Button {
                        runTest()
                    } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing || trimmedKey.isEmpty)
                    if let r = testResult {
                        Text(r)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("AI model")
                } footer: {
                    Text(usingOpenRouter && !customModel.isEmpty
                         ? "Using the model id you typed. Clear it to go back to the list."
                         : "The model has to be able to see images.")
                }

                // What to shoot
                Section {
                    Picker("Look for", selection: $style) {
                        ForEach(ShotStyle.allCases) { s in
                            Text(s.label).tag(s.rawValue)
                        }
                    }
                    Picker("Ideas per scan", selection: $ideasPerScan) {
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text("3").tag(3)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("What to shoot")
                }

                // Automation
                Section {
                    Toggle("Fine-tune framing up close", isOn: $refine)
                    Toggle("Match the look to the shot", isOn: $matchLook)
                    Toggle("Auto-shoot when lined up", isOn: $autoShoot)
                    Toggle("Auto-scan when you hold still", isOn: $autoScan)
                    Toggle("AI-edit every new shot", isOn: $aiEditNew)
                } header: {
                    Text("Hands-free")
                } footer: {
                    Text("Fine-tune takes a second look once zoomed in and tightens the crop. Auto-scan looks for a shot each time you point at a new view and hold still. AI edit picks a look for every photo before it's saved. Each uses a little AI credit.")
                }

                // Camera
                Section {
                    Picker("Start on", selection: $startLens) {
                        Text("0.5x (whole room)").tag("wide")
                        Text("1x").tag("main")
                    }
                    Toggle("Grid", isOn: $showGrid)
                    Toggle("Level line", isOn: $showLevel)
                    Toggle("Haptics", isOn: $haptics)
                } header: {
                    Text("Camera")
                }

                // Default look
                Section {
                    HStack {
                        Text("Look for new shots")
                        Spacer()
                        Text(defaultLookName)
                            .foregroundColor(.secondary)
                    }
                    if defaultLookName != "None" {
                        Button("Remove look from new shots", role: .destructive) {
                            EditSettings.forNewShots = EditSettings()
                            defaultLookName = "None"
                        }
                    }
                } footer: {
                    Text("Set this in the editor with “Use for new shots”. Your shot history always keeps the untouched original.")
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        KeyStore.save(key)
                        dismiss()
                    }
                }
            }
        }
        .tint(Theme.amber)
        .preferredColorScheme(.dark)
        .onDisappear { KeyStore.save(key) }
    }

    private func runTest() {
        KeyStore.save(key)
        testing = true
        testResult = nil
        let k = trimmedKey
        let m = AIConfig.modelID
        Task {
            do {
                let secs = try await AIScout.test(key: k, model: m)
                await MainActor.run {
                    testResult = "Works. \(m) answered in \(String(format: "%.1f", secs))s."
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testResult = error.localizedDescription
                    testing = false
                }
            }
        }
    }
}
