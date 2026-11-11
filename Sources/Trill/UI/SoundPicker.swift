import SwiftUI
import UniformTypeIdentifiers
import TrillCore

struct SoundPickerSheet: View {
    @Binding var selection: String
    let volume: Double

    @ObservedObject private var state = AppState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showImporter = false
    @State private var showTextToSound = false
    @State private var errorMessage: String?

    private let groups: [(Sound.Kind, String)] = [
        (.system, "System"), (.builtIn, "Built-in"), (.user, "Yours"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search sounds", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button { showImporter = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                Button { showTextToSound = true } label: { Label("Text to Sound…", systemImage: "text.bubble") }
            }
            .padding(12)
            Divider()
            List(selection: listSelection) {
                ForEach(groups, id: \.0) { kind, title in
                    let items = sounds(of: kind)
                    if !items.isEmpty {
                        Section(title) {
                            ForEach(items) { sound in
                                row(sound)
                            }
                        }
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
            .overlay {
                if state.sounds.isEmpty { Text("No sounds available").foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout).lineLimit(2)
                } else {
                    Text("Click a sound to select and preview it. Drop audio files here to import.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop") { state.stopPreview() }
                Button("Done") { state.stopPreview(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 520)
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
    }

    private func sounds(of kind: Sound.Kind) -> [Sound] {
        state.sounds.filter { s in
            s.kind == kind && (search.isEmpty || s.name.localizedCaseInsensitiveContains(search))
        }
    }

    private var listSelection: Binding<String?> {
        Binding(
            get: { selection },
            set: { new in
                guard let new, let sound = state.sound(withID: new) else { return }
                selection = new
                state.preview(sound: sound, volume: volume)
            }
        )
    }

    private func row(_ sound: Sound) -> some View {
        HStack {
            Image(systemName: "checkmark")
                .opacity(selection == sound.id ? 1 : 0)
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            Text(sound.name)
            Spacer()
            Button {
                state.preview(sound: sound, volume: volume)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("Preview")
            if sound.kind == .user {
                Button {
                    delete(sound)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this sound")
            }
        }
        .contentShape(Rectangle())
    }

    private func delete(_ sound: Sound) {
        state.deleteSound(sound)
        if selection == sound.id {
            selection = state.soundID(preferring: ["system:Glass"])
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
