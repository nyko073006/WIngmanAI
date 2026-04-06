import SwiftUI
import Supabase

// MARK: - Models

struct BoundaryPreferences: Codable, Equatable {
    var relationshipGoal: String?
    var commStyle: String?
    var dealbreakers: [String]

    init() { dealbreakers = [] }

    enum CodingKeys: String, CodingKey {
        case relationshipGoal = "relationship_goal"
        case commStyle = "comm_style"
        case dealbreakers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        relationshipGoal = try c.decodeIfPresent(String.self, forKey: .relationshipGoal)
        commStyle        = try c.decodeIfPresent(String.self, forKey: .commStyle)
        dealbreakers     = (try? c.decodeIfPresent([String].self, forKey: .dealbreakers)) ?? []
    }
}

// MARK: - BoundarySettingsSheet

struct BoundarySettingsSheet: View {
    let userId: UUID
    var onSave: (BoundaryPreferences) -> Void
    @State private var prefs: BoundaryPreferences
    @Environment(\.dismiss) private var dismiss

    @State private var isSaving = false
    @State private var saveError: String?

    private let accent = Color(.sRGB, red: 0xE8/255, green: 0x60/255, blue: 0x7A/255, opacity: 1)
    private let accentAlt = Color(.sRGB, red: 0xF5/255, green: 0x7C/255, blue: 0x5B/255, opacity: 1)

    init(userId: UUID, current: BoundaryPreferences, onSave: @escaping (BoundaryPreferences) -> Void) {
        self.userId = userId
        self.onSave = onSave
        _prefs = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    goalSection
                    commStyleSection
                    dealbreakersSection
                    disclaimerView
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("Grenzen & Präferenzen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen") { dismiss() }
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().tint(accent)
                        } else {
                            Text("Speichern")
                                .fontWeight(.semibold)
                                .foregroundStyle(accent)
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .alert("Fehler", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var goalSection: some View {
        sectionContainer(title: "Was suchst du?") {
            VStack(spacing: 8) {
                optionButton(key: "serious",    label: "Ernsthafte Beziehung 💍", current: prefs.relationshipGoal) { prefs.relationshipGoal = $0 }
                optionButton(key: "casual",     label: "Casual & offen 🌊",       current: prefs.relationshipGoal) { prefs.relationshipGoal = $0 }
                optionButton(key: "friendship", label: "Freundschaft first 🤝",   current: prefs.relationshipGoal) { prefs.relationshipGoal = $0 }
                optionButton(key: "open",       label: "Mal schauen ✨",          current: prefs.relationshipGoal) { prefs.relationshipGoal = $0 }
            }
        }
    }

    private var commStyleSection: some View {
        sectionContainer(title: "Kommunikationsstil") {
            VStack(spacing: 8) {
                optionButton(key: "texter",   label: "Viel schreiben 💬", current: prefs.commStyle) { prefs.commStyle = $0 }
                optionButton(key: "balanced", label: "Ausgewogen ⚖️",     current: prefs.commStyle) { prefs.commStyle = $0 }
                optionButton(key: "caller",   label: "Lieber reden 📞",   current: prefs.commStyle) { prefs.commStyle = $0 }
            }
        }
    }

    private var dealbreakersSection: some View {
        sectionContainer(title: "Dealbreaker") {
            let chips: [(String, String)] = [
                ("smoking",      "Kein Rauchen 🚭"),
                ("longdistance", "Keine Fernbeziehung 📍"),
                ("kids",         "Kinder no-go 👶"),
                ("alcohol",      "Kein Alkohol 🍺"),
                ("pets",         "Keine Haustiere 🐾")
            ]
            FlowLayout(spacing: 8) {
                ForEach(chips, id: \.0) { key, label in
                    chipToggle(key: key, label: label)
                }
            }
        }
    }

    private var disclaimerView: some View {
        Text("Nur für dich sichtbar – hilft dabei, Missverständnisse zu vermeiden.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.bottom, 8)
    }

    // MARK: - Reusable Components

    private func sectionContainer<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func optionButton(key: String, label: String, current: String?, onSelect: @escaping (String) -> Void) -> some View {
        let isSelected = current == key
        return Button {
            onSelect(key)
        } label: {
            HStack {
                Text(label)
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isSelected ? LinearGradient(colors: [accent, accentAlt], startPoint: .leading, endPoint: .trailing) : LinearGradient(colors: [Color(.tertiarySystemBackground), Color(.tertiarySystemBackground)], startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func chipToggle(key: String, label: String) -> some View {
        let isOn = prefs.dealbreakers.contains(key)
        return Button {
            if isOn {
                prefs.dealbreakers.removeAll { $0 == key }
            } else {
                prefs.dealbreakers.append(key)
            }
        } label: {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(isOn ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isOn ? LinearGradient(colors: [accent, accentAlt], startPoint: .leading, endPoint: .trailing) : LinearGradient(colors: [Color(.tertiarySystemBackground), Color(.tertiarySystemBackground)], startPoint: .leading, endPoint: .trailing))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Save

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }

        struct BoundaryUpdate: Encodable {
            let boundaries: BoundaryPreferences
            let updated_at: String
        }

        do {
            let client = SupabaseClientProvider.shared.client
            _ = try await client
                .from("profiles")
                .update(BoundaryUpdate(
                    boundaries: prefs,
                    updated_at: ISO8601DateFormatter().string(from: Date())
                ))
                .eq("user_id", value: userId.uuidString)
                .execute()
            onSave(prefs)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - FlowLayout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var rowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width + (rows.last!.isEmpty ? 0 : spacing) > width, !rows.last!.isEmpty {
                rows.append([subview])
                rowWidth = size.width
            } else {
                rowWidth += size.width + (rows.last!.isEmpty ? 0 : spacing)
                rows[rows.count - 1].append(subview)
            }
        }

        var totalHeight: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            totalHeight += rowHeight + (i > 0 ? spacing : 0)
        }
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var rows: [[LayoutSubviews.Element]] = [[]]
        var rowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width + (rows.last!.isEmpty ? 0 : spacing) > bounds.width, !rows.last!.isEmpty {
                rows.append([subview])
                rowWidth = size.width
            } else {
                rowWidth += size.width + (rows.last!.isEmpty ? 0 : spacing)
                rows[rows.count - 1].append(subview)
            }
        }

        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
