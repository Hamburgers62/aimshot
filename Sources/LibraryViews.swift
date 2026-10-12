import SwiftUI

// MARK: - Preview rendering

/// Renders a downscaled preview of a shot with its edits, off the main thread.
final class PreviewRenderer: ObservableObject {
    @Published var image: UIImage?
    @Published var lookThumbs: [String: UIImage] = [:]

    var date = Date()
    var specs = ""

    private var base: CIImage?
    private let queue = DispatchQueue(label: "aimshot.preview")
    private var generation = 0

    func load(url: URL, withLookThumbs: Bool) {
        queue.async {
            guard let ui = UIImage(contentsOfFile: url.path)?.normalizedUp(), let cg = ui.cgImage else { return }
            let full = CIImage(cgImage: cg)
            self.base = FilmLab.downscale(full, to: 1400)
            guard withLookThumbs else { return }

            let small = FilmLab.downscale(full, to: 200)
            var thumbs: [String: UIImage] = [:]
            for look in FilmLab.looks {
                var s = EditSettings()
                s.apply(look: look)
                if let out = FilmLab.context.createCGImage(FilmLab.render(small, s), from: small.extent) {
                    thumbs[look.id] = UIImage(cgImage: out)
                }
            }
            DispatchQueue.main.async { self.lookThumbs = thumbs }
        }
    }

    /// Main thread. Only the newest request's result is shown.
    func update(_ s: EditSettings) {
        generation += 1
        let gen = generation
        let date = self.date
        let specs = self.specs
        queue.async {
            guard let base = self.base,
                  var out = FilmLab.context.createCGImage(FilmLab.render(base, s), from: base.extent) else { return }
            if s.frame != .none || s.dateStamp {
                out = FrameRenderer.apply(to: out, style: s.frame, dateStamp: s.dateStamp, date: date, specs: specs)
            }
            let ui = UIImage(cgImage: out)
            DispatchQueue.main.async {
                if gen == self.generation { self.image = ui }
            }
        }
    }
}

// MARK: - Library grid

struct LibraryView: View {
    @ObservedObject private var library = ShotLibrary.shared
    @Environment(\.dismiss) private var dismiss
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            Group {
                if library.shots.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.aperture")
                            .font(.largeTitle)
                        Text("No shots yet")
                            .font(.headline)
                        Text("Photos you take with Aimshot show up here, with the AI's notes.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    }
                    .padding(32)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(library.shots.reversed()) { shot in
                                NavigationLink(value: shot) {
                                    ThumbCell(id: shot.id, version: library.thumbVersion)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Shots")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ShotRecord.self) { shot in
                ShotDetailView(id: shot.id)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Photos app") {
                        if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct ThumbCell: View {
    let id: UUID
    let version: Int

    var body: some View {
        Color.black
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                Group {
                    if let img = ShotLibrary.shared.thumbnail(id) {
                        Image(uiImage: img).resizable().scaledToFill()
                    }
                }
            )
            .clipped()
    }
}

// MARK: - One shot

struct ShotDetailView: View {
    let id: UUID
    @ObservedObject private var library = ShotLibrary.shared
    @StateObject private var renderer = PreviewRenderer()
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        if let shot = library.record(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ZStack {
                        Color.white.opacity(0.05)
                        if let img = renderer.image {
                            Image(uiImage: img).resizable().scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    Text(shot.subject.capitalized)
                        .font(.title2.weight(.bold))
                    if !shot.why.isEmpty {
                        Text("“\(shot.why)”")
                            .italic()
                            .foregroundColor(.secondary)
                    }
                    Label(shot.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(.subheadline)
                    if !shot.specs.isEmpty {
                        Label(shot.specs, systemImage: "camera")
                            .font(.subheadline)
                    }
                    if !shot.edits.isPlain {
                        Label("Look: \(FilmLab.look(shot.edits.look).name)", systemImage: "camera.filters")
                            .font(.subheadline)
                    }

                    Button {
                        editing = true
                    } label: {
                        Label("Edit look & frame", systemImage: "slider.horizontal.3")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.yellow))
                            .foregroundColor(.black)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .padding()
            }
            .navigationTitle("Shot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .onAppear {
                renderer.date = shot.date
                renderer.specs = shot.specs
                renderer.load(url: library.imageURL(shot.id), withLookThumbs: false)
                renderer.update(shot.edits)
            }
            .onChange(of: editing) { open in
                if !open, let s = library.record(id)?.edits { renderer.update(s) }
            }
            .fullScreenCover(isPresented: $editing) {
                EditorView(record: shot)
            }
            .confirmationDialog("Delete this shot from Aimshot?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    library.delete(id)
                    dismiss()
                }
            } message: {
                Text("Copies already saved to Photos stay there.")
            }
        } else {
            Text("Shot not found")
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Editor

struct EditorView: View {
    let record: ShotRecord
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = ShotLibrary.shared
    @StateObject private var renderer = PreviewRenderer()
    @State private var settings: EditSettings
    @State private var tab = 0
    @State private var saving = false
    @State private var message: String? = nil

    init(record: ShotRecord) {
        self.record = record
        _settings = State(initialValue: record.edits)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let img = renderer.image {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                    } else {
                        ProgressView().tint(.white)
                    }
                    if saving {
                        Color.black.opacity(0.5)
                        ProgressView("Saving…")
                            .tint(.white)
                            .foregroundColor(.white)
                    }
                    if let m = message {
                        VStack {
                            Text(m)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.white))
                                .padding(.top, 12)
                            Spacer()
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                Picker("Panel", selection: $tab) {
                    Text("Look").tag(0)
                    Text("Adjust").tag(1)
                    Text("Frame").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 10)

                Group {
                    switch tab {
                    case 0: lookPanel
                    case 1: adjustPanel
                    default: framePanel
                    }
                }
                .frame(height: 200)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(record.subject.capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving)
                }
            }
            .onAppear {
                renderer.date = record.date
                renderer.specs = record.specs
                renderer.load(url: library.imageURL(record.id), withLookThumbs: true)
                renderer.update(settings)
            }
            .onChange(of: settings) { s in
                renderer.update(s)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Panels

    private var lookPanel: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilmLab.looks) { look in
                        let picked = settings.look == look.id
                        Button {
                            settings.apply(look: look)
                        } label: {
                            VStack(spacing: 4) {
                                Group {
                                    if let t = renderer.lookThumbs[look.id] {
                                        Image(uiImage: t).resizable().scaledToFill()
                                    } else {
                                        Color.white.opacity(0.1)
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(picked ? Color.yellow : Color.clear, lineWidth: 2))
                                Text(look.name)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(picked ? .yellow : .white)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            if settings.look != "none" {
                slider("Strength", $settings.intensity, 0...1)
            }
            Button {
                EditSettings.forNewShots = settings
                flash("New shots will use this look")
            } label: {
                Label("Use for new shots", systemImage: "wand.and.stars")
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.top, 12)
    }

    private var adjustPanel: some View {
        ScrollView {
            VStack(spacing: 6) {
                slider("Exposure", $settings.exposure, -1...1)
                slider("Warmth", $settings.warmth, -1...1)
                slider("Fade", $settings.fade, 0...1)
                slider("Grain", $settings.grain, 0...1)
                slider("Halation", $settings.halation, 0...1)
                slider("Vignette", $settings.vignette, 0...1)
            }
            .padding(.vertical, 12)
        }
    }

    private var framePanel: some View {
        VStack(spacing: 16) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FrameStyle.allCases) { style in
                        let picked = settings.frame == style
                        Button {
                            settings.frame = style
                        } label: {
                            Text(style.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(picked ? .black : .white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(picked ? Color.yellow : Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            Toggle("Date stamp", isOn: $settings.dateStamp)
                .padding(.horizontal)
            Button {
                EditSettings.forNewShots = settings
                flash("New shots will use this look & frame")
            } label: {
                Label("Use for new shots", systemImage: "wand.and.stars")
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.top, 16)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 76, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.0f", value.wrappedValue * 100))
                .font(.footnote.monospacedDigit())
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal)
    }

    private func flash(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if message == text { message = nil }
        }
    }

    // MARK: Save

    private func save() {
        saving = true
        let url = library.imageURL(record.id)
        let s = settings
        let date = record.date
        let specs = record.specs
        var updated = record
        updated.edits = s

        DispatchQueue.global(qos: .userInitiated).async {
            guard let ui = UIImage(contentsOfFile: url.path)?.normalizedUp(),
                  let cg = ui.cgImage,
                  let out = FilmLab.renderFinal(cg, s, date: date, specs: specs),
                  let data = PhotoSaver.encode(out, metadata: PhotoSpecs.metadata(of: url)) else {
                DispatchQueue.main.async {
                    saving = false
                    flash("Couldn't render the photo")
                }
                return
            }
            let thumb = UIImage(cgImage: out).preparingThumbnail(of: CGSize(width: 300, height: 300))
            PhotoSaver.save(photo: data, raw: nil) { ok in
                saving = false
                library.update(updated, thumb: thumb)
                if ok {
                    dismiss()
                } else {
                    flash("Allow Photos access in Settings to save")
                }
            }
        }
    }
}
