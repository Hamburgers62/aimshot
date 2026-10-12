import SwiftUI
import Security
import AVFoundation

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

enum AIModel: String, CaseIterable, Identifiable {
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    case opus = "claude-opus-5-5"

    var id: String { rawValue }

    /// Same model on OpenRouter.
    var openRouterID: String {
        switch self {
        case .sonnet: return "anthropic/claude-sonnet-5.5"
        case .haiku: return "anthropic/claude-haiku-5.5"
        case .opus: return "anthropic/claude-opus-5.5"
        }
    }

    var label: String {
        switch self {
        case .sonnet: return "Sonnet 5.5 (best balance)"
        case .haiku: return "Haiku 5.5 (fastest, cheapest)"
        case .opus: return "Opus 5.5 (smartest, slower)"
        }
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

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key: String = KeyStore.load()
    @AppStorage("aiModel") private var model: String = AIModel.sonnet.rawValue
    @AppStorage("autoShoot") private var autoShoot: Bool = true
    @AppStorage("customModel") private var customModel: String = ""

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var keyStatus: String {
        if trimmedKey.isEmpty {
            return "No key yet: Scan uses a basic on-device guess. Paste a Claude key (platform.claude.com) or an OpenRouter key (openrouter.ai/keys)."
        }
        return AIScout.isOpenRouter(trimmedKey)
            ? "OpenRouter key: uses your OpenRouter credits. Saved on this phone only."
            : "Claude key: uses your Anthropic credits. Saved on this phone only."
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    Picker("Model", selection: $model) {
                        ForEach(AIModel.allCases) { m in
                            Text(m.label).tag(m.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("AI model")
                }

                if AIScout.isOpenRouter(trimmedKey) {
                    Section {
                        TextField("e.g. openai/gpt-6-luna", text: $customModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Other OpenRouter model (optional)")
                    } footer: {
                        Text("Leave empty to use the model picked above. Must be a model that can see images.")
                    }
                }

                Section {
                    Toggle("Auto-shoot when lined up", isOn: $autoShoot)
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
        .onDisappear { KeyStore.save(key) }
    }
}
