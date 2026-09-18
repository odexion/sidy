import AppKit
import Observation
import SwiftUI

/// One scratch note, saved as it is typed.
@Observable
final class Notes {
    var text: String { didSet { UserDefaults.standard.set(text, forKey: "notes.text") } }
    /// True while the note has keyboard focus, so the compact card stays open when the pointer wanders off.
    var editing = false

    init() {
        text = UserDefaults.standard.string(forKey: "notes.text") ?? ""
    }

    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}

/// The sidebar's panel. It takes the keyboard only when a text view asks for it, so clicking tiles
/// or media controls never pulls focus away from the app in front.
final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        becomesKeyOnlyIfNeeded = true
    }
}

struct NotesCard: View {
    let index: Int
    @Environment(Notes.self) private var notes
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var notes = notes
        Card(index: index, title: "Notes", badge: notes.words > 0 ? Badge(text: "\(notes.words) words", color: Theme.muted) : nil) {
            ZStack(alignment: .topLeading) {
                if notes.text.isEmpty {
                    Text("Empty").font(Theme.body).foregroundStyle(Theme.muted).padding(.top, 1)
                }
                TextEditor(text: $notes.text)
                    .font(Theme.body)
                    .foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .textEditorStyle(.plain)
                    .tint(Theme.accent)
                    .focused($focused)
                    // The text view's own line padding would indent the note past the card's title.
                    .padding(.horizontal, -5)
            }
        }
        .onChange(of: focused) { _, focused in notes.editing = focused }
        .onDisappear { notes.editing = false }
    }
}
