import SwiftUI

// MARK: - Preview rendering

/// Renders a downscaled preview of a shot with its edits, off the main thread.
final class PreviewRenderer: ObservableObject {
    @Published var image: UIImage?
    @Published var original: UIImage?
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
            let base = FilmLab.downscale(full, to: 1400)
            self.base = base
            if let plain = FilmLab.context.createCGImage(base, from: base.extent) {
                let img = UIImage(cgImage: plain)
                DispatchQueue.main.async { self.original = img }
            }
            guard withLookThumbs else { return }

            let small = FilmLab.downscale(full, to: 220)
            var thumbs: [String: UIImage] = [:]
            for look in FilmLab.looks {
                var s = EditSettings()
                s.apply(look: look)
                s.grain = 0   // grain just muddies tiny thumbnails
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
        setLatest(gen)
        let date = self.date
        let specs = self.specs
        queue.async {
            guard gen == self.latestGeneration(), let base = self.base,
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

    /// Lets the render queue skip stale requests while you drag a slider.
    private let lock = NSLock()
    private var latest = 0
    private func latestGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        return latest
    }
    private func setLatest(_ g: Int) {
        lock.lock(); latest = g; lock.unlock()
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
                        Text("No shots yet")
                            .font(Theme.title(22))
                            .foregroundColor(Theme.paper)
                        Text("Photos you take show up here, with what the AI saw in them.")
                            .font(Theme.ui(15))
                            .multilineTextAlignment(.center)
                            .foregroundColor(Theme.muted)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
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
        .tint(Theme.amber)
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
                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        Color.black
                        if let img = renderer.image {
                            Image(uiImage: img).resizable().scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(shot.subject.capitalized)
                            .font(Theme.title(26))
                            .foregroundColor(Theme.paper)
                        if !shot.why.isEmpty {
                            Text(shot.why)
                                .font(Theme.note(18))
                                .foregroundColor(Theme.paper.opacity(0.75))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(shot.date.formatted(date: .abbreviated, time: .shortened))
                            if !shot.specs.isEmpty { Text(shot.specs) }
                            if !shot.edits.isPlain {
                                Text("Look: \(FilmLab.look(shot.edits.look).name)")
                            }
                            if let note = shot.editNote, !note.isEmpty {
                                Text("AI edit: \(note)")
                            }
                        }
                        .font(Theme.ui(14))
                        .foregroundColor(Theme.muted)
                        .padding(.top, 6)

                        Button {
                            editing = true
                        } label: {
                            Text("Edit look and frame")
                                .font(Theme.ui(16, .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Capsule().fill(Theme.amber))
                                .foregroundColor(.black)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 14)
                    }
                    .padding(20)
                }
            }
            .background(Color.black)
            .navigationTitle("")
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
            Text("This shot was deleted.")
                .foregroundColor(Theme.muted)
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
    @State private var comparing = false
    @State private var aiBusy = false
    @State private var aiNote: String? = nil
    @State private var message: String? = nil

    private let tabs = ["Look", "Adjust", "Frame"]

    init(record: ShotRecord) {
        self.record = record
        _settings = State(initialValue: record.edits)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            // Photo. Hold to see the original.
            ZStack {
                Color.black
                if let img = (comparing ? renderer.original : renderer.image) ?? renderer.image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(.horizontal, 12)
                } else {
                    ProgressView().tint(Theme.paper)
                }
                VStack {
                    Spacer()
                    Text(comparing ? "Original" : "Hold to compare")
                        .font(Theme.ui(12, .semibold))
                        .foregroundColor(comparing ? Theme.amber : Theme.muted)
                        .padding(.bottom, 8)
                }
                if saving {
                    Color.black.opacity(0.55)
                    ProgressView("Saving").tint(Theme.paper).foregroundColor(Theme.paper)
                }
                if let m = message {
                    VStack {
                        Text(m)
                            .font(Theme.ui(14, .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Theme.paper))
                            .padding(.top, 10)
                        Spacer()
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.12, maximumDistance: 40, pressing: { down in
                comparing = down
            }, perform: {})

            tabBar
                .padding(.top, 10)

            // All panels stay alive; only the visible one is shown (no jumpy re-layout).
            ZStack(alignment: .top) {
                lookPanel.opacity(tab == 0 ? 1 : 0).allowsHitTesting(tab == 0)
                adjustPanel.opacity(tab == 1 ? 1 : 0).allowsHitTesting(tab == 1)
                framePanel.opacity(tab == 2 ? 1 : 0).allowsHitTesting(tab == 2)
            }
            .frame(height: 236)
            .transaction { $0.animation = nil }
        }
        .background(Color.black.ignoresSafeArea())
        .tint(Theme.amber)
        .preferredColorScheme(.dark)
        .onAppear {
            renderer.date = record.date
            renderer.specs = record.specs
            renderer.load(url: library.imageURL(record.id), withLookThumbs: true)
            render()
        }
        .onChange(of: settings) { _ in render() }
    }

    private func render() {
        renderer.update(settings)
    }

    // MARK: Header + tabs

    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(Theme.ui(16))
                .foregroundColor(Theme.paper)
            Spacer()
            Text(record.subject.capitalized)
                .font(Theme.title(17))
                .foregroundColor(Theme.paper)
                .lineLimit(1)
            Spacer()
            Button("Save") { save() }
                .font(Theme.ui(16, .semibold))
                .foregroundColor(Theme.amber)
                .disabled(saving)
        }
        .padding(.horizontal, 20)
        .frame(height: 50)
    }

    private var tabBar: some View {
        HStack(spacing: 28) {
            ForEach(tabs.indices, id: \.self) { i in
                Button {
                    tab = i
                } label: {
                    VStack(spacing: 6) {
                        Text(tabs[i])
                            .font(Theme.ui(15, tab == i ? .semibold : .regular))
                            .foregroundColor(tab == i ? Theme.paper : Theme.muted)
                        Capsule()
                            .fill(tab == i ? Theme.amber : Color.clear)
                            .frame(width: 18, height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Look panel

    private var lookPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    aiEdit()
                } label: {
                    HStack(spacing: 6) {
                        if aiBusy {
                            ProgressView().scaleEffect(0.7).tint(Theme.amber)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(aiBusy ? "Developing" : "Let AI edit")
                    }
                    .font(Theme.ui(14, .semibold))
                    .foregroundColor(Theme.amber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .overlay(Capsule().stroke(Theme.amber.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(aiBusy)

                if let note = aiNote {
                    Text(note)
                        .font(Theme.note(15))
                        .foregroundColor(Theme.paper.opacity(0.8))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            filmStrip

            if settings.look != "none" {
                sliderRow("Strength", $settings.intensity, 0...1)
            }

            HStack {
                Button("Use for new shots") {
                    EditSettings.forNewShots = settings
                    flash("New shots will use this look")
                }
                Spacer()
                Button("Reset") {
                    settings = EditSettings()
                    aiNote = nil
                }
                .foregroundColor(Theme.muted)
            }
            .font(Theme.ui(14, .semibold))
            .padding(.horizontal, 16)
        }
    }

    /// Looks shown as frames on a strip of film.
    private var filmStrip: some View {
        let count = FilmLab.looks.count
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 5) {
                sprockets(count)
                HStack(spacing: 8) {
                    ForEach(FilmLab.looks) { look in
                        let picked = settings.look == look.id
                        Button {
                            settings.apply(look: look)
                            aiNote = nil
                        } label: {
                            VStack(spacing: 5) {
                                Group {
                                    if let t = renderer.lookThumbs[look.id] {
                                        Image(uiImage: t).resizable().scaledToFill()
                                    } else {
                                        Color.white.opacity(0.06)
                                    }
                                }
                                .frame(width: 66, height: 66)
                                .clipped()
                                .overlay(Rectangle().stroke(picked ? Theme.amber : Color.clear, lineWidth: 2))
                                Text(look.name)
                                    .font(Theme.ui(11, picked ? .semibold : .regular))
                                    .foregroundColor(picked ? Theme.amber : Theme.paper.opacity(0.75))
                                    .lineLimit(1)
                            }
                            .frame(width: 74)
                        }
                        .buttonStyle(.plain)
                    }
                }
                sprockets(count)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color(red: 0.06, green: 0.055, blue: 0.05))
        }
    }

    private func sprockets(_ frames: Int) -> some View {
        HStack(spacing: 9) {
            ForEach(0..<(frames * 5), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.13))
                    .frame(width: 7, height: 5)
            }
        }
        .frame(width: CGFloat(frames) * 82, alignment: .leading)
        .clipped()
    }

    // MARK: Adjust panel

    private var adjustPanel: some View {
        ScrollView {
            VStack(spacing: 4) {
                sliderRow("Exposure", $settings.exposure, -1...1)
                sliderRow("Warmth", $settings.warmth, -1...1)
                sliderRow("Fade", $settings.fade, 0...1)
                sliderRow("Grain", $settings.grain, 0...1)
                sliderRow("Halation", $settings.halation, 0...1)
                sliderRow("Vignette", $settings.vignette, 0...1)
            }
            .padding(.vertical, 14)
        }
    }

    // MARK: Frame panel

    private var framePanel: some View {
        VStack(spacing: 16) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(FrameStyle.allCases) { style in
                        let picked = settings.frame == style
                        Button {
                            settings.frame = style
                        } label: {
                            VStack(spacing: 6) {
                                framePreview(style)
                                    .frame(width: 52, height: 64)
                                    .overlay(RoundedRectangle(cornerRadius: 3)
                                        .stroke(picked ? Theme.amber : Color.clear, lineWidth: 2)
                                        .padding(-3))
                                Text(style.label)
                                    .font(Theme.ui(12, picked ? .semibold : .regular))
                                    .foregroundColor(picked ? Theme.amber : Theme.paper.opacity(0.75))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
            }
            Toggle("Date stamp", isOn: $settings.dateStamp)
                .font(Theme.ui(15))
                .foregroundColor(Theme.paper)
                .padding(.horizontal, 16)
            HStack {
                Button("Use for new shots") {
                    EditSettings.forNewShots = settings
                    flash("New shots will use this look and frame")
                }
                Spacer()
            }
            .font(Theme.ui(14, .semibold))
            .padding(.horizontal, 16)
        }
    }

    /// Tiny drawing of each frame style.
    @ViewBuilder
    private func framePreview(_ style: FrameStyle) -> some View {
        let photo = LinearGradient(colors: [Color(white: 0.45), Color(white: 0.25)],
                                   startPoint: .top, endPoint: .bottom)
        switch style {
        case .none:
            Rectangle().fill(photo)
        case .white:
            ZStack { Color.white; Rectangle().fill(photo).padding(3) }
        case .paper:
            ZStack(alignment: .top) {
                Color(red: 0.96, green: 0.945, blue: 0.915)
                Rectangle().fill(photo).padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 14)
            }
        case .black:
            ZStack { Color.black; Rectangle().fill(photo).padding(3) }
                .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
        case .specs:
            ZStack(alignment: .top) {
                Color.white
                Rectangle().fill(photo).padding(.horizontal, 3).padding(.top, 3).padding(.bottom, 11)
                VStack {
                    Spacer()
                    Rectangle().fill(Color(white: 0.4)).frame(width: 30, height: 2).padding(.bottom, 4)
                }
            }
        }
    }

    // MARK: Pieces

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Theme.ui(14))
                .foregroundColor(Theme.paper.opacity(0.85))
                .frame(width: 74, alignment: .leading)
            Slider(value: value, in: range)
            Button {
                value.wrappedValue = range.lowerBound < 0 ? 0 : (title == "Strength" ? 1 : 0)
            } label: {
                Text(String(format: "%.0f", value.wrappedValue * 100))
                    .font(Theme.ui(13).monospacedDigit())
                    .foregroundColor(Theme.muted)
                    .frame(width: 38, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private func flash(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if message == text { message = nil }
        }
    }

    // MARK: AI edit

    private func aiEdit() {
        let key = AIConfig.key
        guard !key.isEmpty else {
            flash("Add an API key in Settings first")
            return
        }
        aiBusy = true
        let model = AIConfig.modelID
        let url = library.imageURL(record.id)
        let subject = record.subject
        let keepFrame = settings.frame
        let keepStamp = settings.dateStamp
        Task {
            do {
                guard let img = UIImage(contentsOfFile: url.path),
                      let small = img.preparingThumbnail(of: CGSize(width: 1024, height: 1024)),
                      let jpeg = small.jpegData(compressionQuality: 0.7) else {
                    throw AIScoutError.unreadable("couldn't read the photo")
                }
                let result = try await AIScout.suggestEdit(jpeg: jpeg, key: key, model: model, subject: subject)
                await MainActor.run {
                    var s = result.settings
                    s.frame = keepFrame
                    s.dateStamp = keepStamp
                    settings = s
                    aiNote = result.note.isEmpty ? nil : result.note
                    aiBusy = false
                }
            } catch {
                await MainActor.run {
                    aiBusy = false
                    flash(error.localizedDescription)
                }
            }
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
        if let note = aiNote { updated.editNote = note }

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
