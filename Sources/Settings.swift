import SwiftUI
import Security

enum AIModel: String, CaseIterable, Identifiable {
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    case opus = "claude-opus-5-5"

    var id: String { rawValue }

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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste from clipboard") {
                        if let s = UIPasteboard.general.string { key = s }
                    }
                } header: {
                    Text("Claude API key")
                } footer: {
                    Text(key.isEmpty
                         ? "No key yet: Scan uses a basic on-device guess. Get a key at platform.claude.com → API Keys."
                         : "Key saved on this phone only.")
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
