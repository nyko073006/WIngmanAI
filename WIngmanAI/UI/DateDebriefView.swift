import SwiftUI
import Supabase
import Combine

// MARK: - ViewModel

@MainActor
final class DateDebriefViewModel: ObservableObject {
    @Published var rating: Int = 3
    @Published var notes: String = ""
    @Published var isLoading: Bool = false
    @Published var feedback: String? = nil
    @Published var patterns: String? = nil
    @Published var errorText: String? = nil

    private let matchId: UUID

    init(matchId: UUID) {
        self.matchId = matchId
    }

    func submit() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorText = nil

        do {
            let session = try await SupabaseClientProvider.shared.client.auth.session
            let token = session.accessToken

            guard let url = URL(string: "\(SupabaseClientProvider.shared.supabaseURL)/functions/v1/ai-debrief") else { return }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "match_id": matchId.uuidString,
                "rating": rating,
                "notes": notes
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, _) = try await URLSession.shared.data(for: req)
            let decoded = try JSONDecoder().decode(DebriefResponse.self, from: data)
            feedback = decoded.feedback
            patterns = decoded.patterns
        } catch {
            errorText = error.localizedDescription
        }
    }

    private struct DebriefResponse: Decodable {
        let feedback: String
        let patterns: String?
    }
}

// MARK: - View

struct DateDebriefView: View {
    let matchName: String
    let matchId: UUID

    @StateObject private var vm: DateDebriefViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var notesFocused: Bool

    private let brand = Color(.sRGB, red: 0xE8/255.0, green: 0x60/255.0, blue: 0x7A/255.0, opacity: 1.0)

    init(matchName: String, matchId: UUID) {
        self.matchName = matchName
        self.matchId = matchId
        _vm = StateObject(wrappedValue: DateDebriefViewModel(matchId: matchId))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // Header
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Wie war das Date mit \(matchName)?")
                            .font(.title3.weight(.bold))
                        Text("Dein persönliches Debrief — nur für dich sichtbar.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Star Rating
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Bewertung")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            ForEach(1...5, id: \.self) { star in
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                        vm.rating = star
                                    }
                                } label: {
                                    Image(systemName: star <= vm.rating ? "star.fill" : "star")
                                        .font(.system(size: 34))
                                        .foregroundStyle(star <= vm.rating ? brand : Color(.systemGray4))
                                        .scaleEffect(star == vm.rating ? 1.15 : 1.0)
                                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: vm.rating)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Text(ratingLabel(vm.rating))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Notes
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Was ist passiert?")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(.secondarySystemBackground))

                            if vm.notes.isEmpty {
                                Text("Was lief gut? Was würdest du anders machen?\nKein Druck – auch kurze Notizen helfen.")
                                    .font(.subheadline)
                                    .foregroundStyle(Color(.tertiaryLabel))
                                    .padding(14)
                            }

                            TextEditor(text: $vm.notes)
                                .font(.subheadline)
                                .focused($notesFocused)
                                .frame(minHeight: 110)
                                .padding(10)
                                .scrollContentBackground(.hidden)
                        }
                        .frame(minHeight: 130)
                    }

                    // AI Button
                    if vm.feedback == nil {
                        Button {
                            notesFocused = false
                            Task { await vm.submit() }
                        } label: {
                            HStack(spacing: 8) {
                                if vm.isLoading {
                                    ProgressView().scaleEffect(0.85).tint(.white)
                                    Text("AI analysiert…")
                                } else {
                                    Image(systemName: "sparkles")
                                    Text("AI-Auswertung starten")
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(
                                    colors: [brand, Color(.sRGB, red: 0xF5/255, green: 0x7C/255, blue: 0x5B/255, opacity: 1)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isLoading)
                    }

                    // Error
                    if let err = vm.errorText {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    // AI Feedback
                    if let feedback = vm.feedback {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Dein Feedback", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(brand)

                            Text(feedback)
                                .font(.subheadline)
                                .lineSpacing(4)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(brand.opacity(0.07))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Patterns
                    if let patterns = vm.patterns {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Muster erkannt", systemImage: "chart.line.uptrend.xyaxis")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.purple)

                            Text(patterns)
                                .font(.subheadline)
                                .lineSpacing(4)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.purple.opacity(0.07))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if vm.feedback != nil {
                        Button {
                            dismiss()
                        } label: {
                            Text("Fertig")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(brand)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(brand.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
                .animation(.easeInOut(duration: 0.3), value: vm.feedback != nil)
            }
            .navigationTitle("Date Debrief")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Schließen") { dismiss() }
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func ratingLabel(_ r: Int) -> String {
        switch r {
        case 1: return "Lief nicht so gut"
        case 2: return "Naja…"
        case 3: return "War okay"
        case 4: return "Hat Spaß gemacht!"
        case 5: return "Mega Date! 🔥"
        default: return ""
        }
    }
}
