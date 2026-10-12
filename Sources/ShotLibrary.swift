import UIKit

struct ShotRecord: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var date: Date
    var subject: String
    var why: String
    var specs: String
    var edits: EditSettings
    var editNote: String? = nil
    var score: Int? = nil

    static func == (a: ShotRecord, b: ShotRecord) -> Bool { a.id == b.id && a.edits == b.edits }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Every shot you take, kept in the app with the AI's note, so you can come back and re-edit.
final class ShotLibrary: ObservableObject {
    static let shared = ShotLibrary()

    @Published private(set) var shots: [ShotRecord] = []
    /// Bumped when a thumbnail changes, so views reload it.
    @Published private(set) var thumbVersion = 0

    private let folder: URL
    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("Shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([ShotRecord].self, from: data) {
            shots = list
        }
    }

    func imageURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).heic") }
    func thumbURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString)-thumb.jpg") }

    func record(_ id: UUID) -> ShotRecord? { shots.first { $0.id == id } }

    func thumbnail(_ id: UUID) -> UIImage? {
        UIImage(contentsOfFile: thumbURL(id).path)
    }

    var latestThumbnail: UIImage? {
        shots.last.flatMap { thumbnail($0.id) }
    }

    /// Writes the files (call off the main thread), then adds the record on main.
    func store(photo: Data, thumb: UIImage, subject: String, why: String, specs: String, edits: EditSettings,
               editNote: String? = nil, score: Int? = nil) {
        let id = UUID()
        try? photo.write(to: imageURL(id))
        if let jpg = thumb.jpegData(compressionQuality: 0.8) {
            try? jpg.write(to: thumbURL(id))
        }
        let record = ShotRecord(id: id, date: Date(), subject: subject, why: why, specs: specs, edits: edits,
                                editNote: editNote, score: score)
        DispatchQueue.main.async {
            self.shots.append(record)
            self.persist()
        }
    }

    /// Main thread.
    func update(_ record: ShotRecord, thumb: UIImage?) {
        if let thumb = thumb, let jpg = thumb.jpegData(compressionQuality: 0.8) {
            try? jpg.write(to: thumbURL(record.id))
            thumbVersion += 1
        }
        if let i = shots.firstIndex(where: { $0.id == record.id }) {
            shots[i] = record
            persist()
        }
    }

    /// Main thread. Removes it from the app only; anything saved to Photos stays.
    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: imageURL(id))
        try? FileManager.default.removeItem(at: thumbURL(id))
        shots.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(shots) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
