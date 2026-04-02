import SwiftUI

// MARK: - Closure Flow Sheet
// Core Wingman USP: Anti-Ghosting / Ehrlicher Abschluss statt Stille

struct ClosureFlowSheet: View {
    let matchId: UUID
    let matchName: String
    let daysSilent: Int
    var onSendMessage: (String) -> Void
    var onEndSilently: () -> Void
    var onKeepGoing: () -> Void

    @State private var selected: String? = nil
    @State private var didClose = false
    @State private var showDebrief = false
    @Environment(\.dismiss) private var dismiss

    private let closureMessages = [
        "Hey! Ich glaube, unsere Energie passt gerade nicht ganz zusammen – aber ich schätze unser Gespräch wirklich. Alles Gute für dich! 🤍",
        "Ich wollte ehrlich mit dir sein: Ich spüre keinen romantischen Funken, aber du wirkst wie ein toller Mensch. Ich wünsche dir viel Glück! ✨",
        "Hey, ich wollte dich nicht einfach stehen lassen. Für mich passt es leider nicht – aber das hat nichts mit dir zu tun. Pass auf dich auf! 🙏"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if didClose {
                        debriefPrompt
                    } else {
                        header
                        messageSelector
                        actions
                        disclaimer
                    }
                }
                .padding(.vertical, 16)
                .animation(.easeInOut(duration: 0.3), value: didClose)
            }
            .navigationTitle(didClose ? "Wie war es?" : "Ehrlicher Abschluss")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !didClose {
                        Button("Abbrechen") { dismiss() }
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(isPresented: $showDebrief) {
                DateDebriefView(matchName: matchName, matchId: matchId)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var debriefPrompt: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.1))
                        .frame(width: 80, height: 80)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.green)
                }
                Text("Abschluss gesendet ✓")
                    .font(.title3.weight(.bold))
                Text("Gut gemacht – ehrlich sein ist Respekt.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            Divider()

            VStack(spacing: 8) {
                Text("Hattet ihr schon ein Date?")
                    .font(.headline)
                Text("Ein kurzes Debrief hilft dir, beim nächsten Date besser zu werden.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .padding(.horizontal, 16)

            VStack(spacing: 10) {
                Button {
                    showDebrief = true
                } label: {
                    Label("Ja, Date Debrief schreiben", systemImage: "star.bubble.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(colors: [closureBrand, closureBrandAlt], startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                } label: {
                    Text("Nein danke")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(closureBrand.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 36))
                    .foregroundStyle(closureBrand)
            }

            Text("Seit \(daysSilent) Tagen kein Kontakt")
                .font(.title3.weight(.bold))

            Text("Du und \(matchName) habt euch eine Weile nicht geschrieben. Ein ehrlicher Abschluss ist respektvoller als Stille.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var messageSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wähle eine ehrliche Nachricht:")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            ForEach(closureMessages, id: \.self) { msg in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selected = (selected == msg) ? nil : msg
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: selected == msg ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(selected == msg ? closureBrand : Color.secondary.opacity(0.4))
                            .padding(.top, 2)
                        Text(msg)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineSpacing(3)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(selected == msg ? closureBrand.opacity(0.07) : Color(.systemGray6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(selected == msg ? closureBrand.opacity(0.35) : Color.clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                guard let msg = selected else { return }
                onSendMessage(msg)
                withAnimation { didClose = true }
            } label: {
                Label("Nachricht senden & Match beenden", systemImage: "paperplane.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        selected != nil
                            ? AnyShapeStyle(LinearGradient(
                                colors: [closureBrand, closureBrandAlt],
                                startPoint: .leading, endPoint: .trailing
                              ))
                            : AnyShapeStyle(Color.secondary.opacity(0.3))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(selected == nil)

            HStack(spacing: 10) {
                Button {
                    onEndSilently()
                    withAnimation { didClose = true }
                } label: {
                    Text("Leise beenden")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                    onKeepGoing()
                } label: {
                    Text("Doch noch schreiben")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(closureBrand)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(closureBrand.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private var disclaimer: some View {
        Text("Wingman 🤝 Keine Nachricht wird ohne deine Bestätigung gesendet.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    private let closureBrand    = Color(.sRGB, red: 0xE8/255, green: 0x60/255, blue: 0x7A/255, opacity: 1)
    private let closureBrandAlt = Color(.sRGB, red: 0xF5/255, green: 0x7C/255, blue: 0x5B/255, opacity: 1)
}
