import SwiftUI
import UniformTypeIdentifiers
import TrillCore

struct SoundPickerSheet: View {
    @Binding var selection: String
    let volume: Double
    /// Called when the user presses Done (not when the sheet is dismissed another way).
    var onDone: (() -> Void)? = nil

    @ObservedObject private var state = AppState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var collapsed = Set<String>()
    @State private var didSetupCollapse = false
    @State private var showImporter = false
    @State private var showTextToSound = false
    @State private var errorMessage: String?
    @State private var soundToDelete: Sound?

    private struct SoundSection: Identifiable {
        let title: String
        let symbol: String
        let sounds: [Sound]
        var id: String { title }
    }

    /// Yours, then one section per bundled pack, then Built-in, then System.
    private var sections: [SoundSection] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let all = state.sounds.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
        var result: [SoundSection] = []
        let yours = all.filter { $0.kind == .user }
        if !yours.isEmpty { result.append(SoundSection(title: "Yours", symbol: "person.crop.circle", sounds: yours)) }
        let packed = all.filter { $0.kind == .builtIn && $0.group != nil }
        let groupNames = Array(Set(packed.compactMap(\.group))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for g in groupNames {
            result.append(SoundSection(title: g, symbol: "square.stack", sounds: packed.filter { $0.group == g }))
        }
        let builtIn = all.filter { $0.kind == .builtIn && $0.group == nil }
        if !builtIn.isEmpty { result.append(SoundSection(title: "Built-in", symbol: "waveform", sounds: builtIn)) }
        let system = all.filter { $0.kind == .system }
        if !system.isEmpty { result.append(SoundSection(title: "System", symbol: "macwindow", sounds: system)) }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollViewReader { proxy in
            List(selection: listSelection) {
                ForEach(sections) { section in
                    sectionHeader(section)
                        .listRowSeparator(.hidden)
                        .padding(.top, 6)
                    if isExpanded(section) {
                        ForEach(section.sounds) { sound in
                            row(sound)
                                .id(sound.id)
                                .tag(sound.id)
                                .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .onAppear {
                guard !selection.isEmpty else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo(selection, anchor: .center) }
            }
            .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
            .overlay {
                if state.sounds.isEmpty {
                    Text("No sounds available").foregroundStyle(.secondary)
                } else if sections.isEmpty {
                    Text("No sounds match “\(search)”").foregroundStyle(.secondary)
                }
            }
            }
            bottomBar
        }
        .frame(width: 480, height: 600)
        .onAppear(perform: setupCollapse)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showTextToSound) {
            TextToSoundSheet { sound in selection = sound.id }
        }
        .alert("Delete this sound?", isPresented: Binding(get: { soundToDelete != nil },
                                                           set: { if !$0 { soundToDelete = nil } }),
               presenting: soundToDelete) { sound in
            Button("Delete", role: .destructive) { delete(sound) }
            Button("Cancel", role: .cancel) {}
        } message: { sound in
            Text(deleteMessage(for: sound))
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search sounds", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .fieldChrome()
            HStack {
                Text(currentName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { showImporter = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                Button { showTextToSound = true } label: { Label("Text to Sound…", systemImage: "text.bubble") }
            }
            .controlSize(.small)
        }
        .padding(14)
    }

    private var currentName: String {
        if let s = state.sound(withID: selection) { return "Selected: \(s.name)" }
        return "No sound selected"
    }

    private var bottomBar: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout).lineLimit(2)
                } else {
                    Text("Click a sound to select and preview it. Drop audio files here to import.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop") { state.stopPreview() }
                    .glassButton()
                Button("Done") { state.stopPreview(); onDone?(); dismiss() }
                    .glassButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
            .glassCard(cornerRadius: 22)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    private func sectionHeader(_ section: SoundSection) -> some View {
        let expanded = isExpanded(section)
        return Button {
            guard search.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                if collapsed.contains(section.id) { collapsed.remove(section.id) } else { collapsed.insert(section.id) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                Text(section.title).font(.subheadline.weight(.semibold))
                Text("\(section.sounds.count)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func isExpanded(_ section: SoundSection) -> Bool {
        !search.isEmpty || !collapsed.contains(section.id)
    }

    /// Packs start collapsed (there may be dozens of sounds), except the one holding the current selection.
    private func setupCollapse() {
        guard !didSetupCollapse else { return }
        didSetupCollapse = true
        let selectedGroup = state.sound(withID: selection)?.group
        let packs = Set(state.sounds.compactMap { $0.kind == .builtIn ? $0.group : nil })
        collapsed = packs.filter { $0 != selectedGroup }
    }

    private var listSelection: Binding<String?> {
        Binding(
            get: { selection.isEmpty ? nil : selection },
            set: { new in
                guard let new, let sound = state.sound(withID: new) else { return }
                selection = new
                state.preview(sound: sound, volume: volume)
            }
        )
    }

    private func row(_ sound: Sound) -> some View {
        let selected = selection == sound.id
        return HStack(spacing: 8) {
            Button {
                state.preview(sound: sound, volume: volume)
            } label: {
                Image(systemName: "play.circle.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .help("Preview")
            Text(sound.name).fontWeight(selected ? .semibold : .regular)
            Spacer()
            if sound.kind == .user {
                Button {
                    soundToDelete = sound
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this sound")
            }
            if selected {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.bold)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func deleteMessage(for sound: Sound) -> String {
        let used = state.rules(using: sound).count
        var text = "“\(sound.name)” will be removed from your library."
        if used > 0 {
            let fallback = state.fallbackSound(excluding: sound.id)?.name ?? "a system sound"
            text += " \(used == 1 ? "1 rule uses" : "\(used) rules use") it and will switch to \(fallback)."
        }
        return text
    }

    private func delete(_ sound: Sound) {
        let fallback = state.fallbackSound(excluding: sound.id)
        state.deleteSound(sound)
        if selection == sound.id {
            selection = fallback?.id ?? state.soundID(preferring: ["system:Glass"])
        }
    }

    private func importFiles(_ urls: [URL]) {
        errorMessage = nil
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        do {
            let added = try state.importSounds(from: urls)
            if let first = added.first { selection = first.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { importFiles([url]) }
            }
        }
        return handled
    }
}

struct TextToSoundSheet: View {
    var onCreated: (Sound) -> Void

    @ObservedObject private var state = AppState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var name = ""
    @State private var voiceID: String?
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        let voices = state.voices
        VStack(alignment: .leading, spacing: 14) {
            Text("Text to Sound").font(.headline)
            Text("Turn a short phrase into a sound saved in your library.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Text", text: $text, prompt: Text("e.g. Deploy finished"))
                Picker("Voice", selection: $voiceID) {
                    Text("System default").tag(String?.none)
                    ForEach(voices) { v in
                        Text("\(v.name) (\(v.language))").tag(String?.some(v.id))
                    }
                }
                TextField("Name", text: $name, prompt: Text(defaultName))
            }
            .formStyle(.columns)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var defaultName: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Spoken sound" : String(t.prefix(30))
    }

    private func create() {
        working = true
        errorMessage = nil
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : name
        Task { @MainActor in
            do {
                let sound = try await state.generateSpokenSound(text: text, voiceID: voiceID, name: finalName)
                onCreated(sound)
                working = false
                dismiss()
            } catch {
                working = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
