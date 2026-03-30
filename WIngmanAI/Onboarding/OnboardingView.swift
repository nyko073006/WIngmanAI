//
//  OnboardingView.swift
//  WingmanAI
//

import SwiftUI
import Combine
import Supabase
import PhotosUI
import CoreLocation
import MapKit
import UIKit

struct OnboardingView: View {
    @EnvironmentObject var auth: AppAuthService
    @StateObject private var ai = OnboardingAIViewModel()
    @StateObject private var location = LocationService()

    let onFinished: () -> Void

    enum Step: Int, CaseIterable {
        case basics, ai, finish
    }

    @State private var step: Step = .basics
    @State private var stepForward: Bool = true
    @State private var showCompletion: Bool = false
    @State private var showSnapshotCamera: Bool = false

    // REQUIRED
    @State private var is18 = false
    @State private var name = ""
    @State private var birthDate: Date = Calendar.current.date(byAdding: .year, value: -18, to: Date()) ?? Date()
    @State private var gender: Gender = .unset
    @State private var interestedIn: [String] = []
    @State private var city = ""
    @State private var bio = ""

    // Discovery prefs
    @State private var distanceKm: Double = 50
    @State private var ageMin: Double = 18
    @State private var ageMax: Double = 55
    @State private var lookingFor: Set<String> = []
    @State private var showBioAIDirection: Bool = false

    // Slide 1: Interests + Keywords
    @State private var selectedInterests: Set<String> = []
    @State private var selectedKeywords: Set<String> = []

    @State private var isBusy = false
    @State private var isUploadingPhoto = false
    @State private var uploadStatusText: String? = nil
    @State private var error: String?
    @State private var limitHint: String? = nil
    // Draft autosave
    @State private var draftSaveTask: Task<Void, Never>? = nil
    @State private var isDraftSaving: Bool = false
    // Age range
    @State private var ageRangeUnlocked: Bool = false

    // Intro screen
    @State private var showIntro: Bool = true

    // Brand
    private let brand = Color(.sRGB, red: 0xE8/255.0, green: 0x60/255.0, blue: 0x7A/255.0, opacity: 1.0)

    // Limits
    private let minInterestsSelected: Int = 3
    private let maxInterestsSelected: Int = 6
    private let keywordsMustSelect: Int = 3

    // Options (Base44-ish)
    private let interestOptions: [String] = [
        "Reisen", "Musik", "Filme", "Fitness", "Lesen", "Kochen",
        "Fotografie", "Kunst", "Gaming", "Tanzen", "Wandern", "Yoga",
        "Kaffee", "Foodie", "Hunde", "Katzen", "Strand", "Berge",
        "Sport", "Fashion", "Technik", "Meditation", "Konzerte", "Festivals"
    ]

    private let keywordOptions: [String] = [
        "Abenteuerlustig", "Kreativ", "Ambitioniert", "Empathisch",
        "Humorvoll", "Tiefgründig", "Spontan", "Entspannt",
        "Romantisch", "Unabhängig", "Offen", "Introvertiert",
        "Optimistisch", "Pragmatisch", "Leidenschaftlich", "Nachdenklich",
        "Selbstbewusst", "Neugierig"
    ]


    // Photos (Base44-style)
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photoPreviews: [UIImage] = []
    @State private var photoUrls: [String] = []
    @State private var primaryPhotoIndex: Int = 0

    // Upload queue / per-photo state
    private enum UploadState: Equatable {
        case pending
        case uploading
        case done
        case failed(String)
    }

    @State private var photoUploadStates: [UploadState] = []
    @State private var uploadQueue: [(index: Int, data: Data, userId: UUID, isSnapshot: Bool)] = []
    @State private var uploadWorkerRunning: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                appBackground.ignoresSafeArea()

                if showCompletion {
                    completionOverlay
                        .transition(.opacity)
                } else if showIntro {
                    introView
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                } else {
                    VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 14) {
                            header
                            Text(stepTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                        ScrollViewReader { proxy in
                            ScrollView {
                                Color.clear.frame(height: 1).id("TOP")

                                VStack(alignment: .leading, spacing: 18) {
                                    content
                                        .transition(.asymmetric(
                                            insertion: .move(edge: stepForward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: stepForward ? .leading : .trailing).combined(with: .opacity)
                                        ))
                                        .id(step)

                                    if let error {
                                        Text(error)
                                            .font(.footnote)
                                            .foregroundStyle(.red)
                                    }

                                    Spacer(minLength: 140)
                                }
                                .padding(.horizontal, 20)
                                .padding(.top, 8)
                                .padding(.bottom, 8)
                            }
                            .scrollIndicators(.hidden)
                            .scrollDismissesKeyboard(.interactively)
                            .onChange(of: step) { _, _ in
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    proxy.scrollTo("TOP", anchor: .top)
                                }
                            }
                            .onAppear { proxy.scrollTo("TOP", anchor: .top) }
                        }

                        bottomBar
                    }
                    .onTapGesture {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(brand)
        .sheet(isPresented: $showBioAIDirection) {
            BioAIDirectionSheet(
                brand: brand,
                currentBio: bio,
                displayName: name,
                city: city,
                gender: genderLabelDE(),
                interestedIn: interestedIn,
                lookingFor: lookingFor.sorted().joined(separator: ","),
                interests: Array(selectedInterests).sorted(),
                keywords: Array(selectedKeywords).sorted(),
                ai: ai
            ) { selected in
                bio = selected
            }
            .presentationDetents([.large])
        }
        .onChange(of: photoItems) { _, _ in
            guard let session = auth.session else { return }
            Task {
                let existingCount = photoPreviews.count
                let newItems = Array(photoItems.dropFirst(existingCount))
                for item in newItems {
                    if photoPreviews.count >= 6 { break }
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let ui = UIImage(data: data) {
                        let newIndex = await MainActor.run { () -> Int in
                            self.photoPreviews.append(ui)
                            self.photoUploadStates.append(.pending)
                            return self.photoPreviews.count - 1
                        }

                        let uploadData = compressJPEG(ui) ?? data
                        enqueueUpload(index: newIndex, data: uploadData, userId: session.user.id)
                    }
                }
            }
        }
        .task(id: auth.session?.user.id) {
            guard let userId = auth.session?.user.id else { return }
            guard let draft = try? await OnboardingService.shared.fetchProfileDraft(userId: userId) else { return }
            restoreDraft(draft)
        }
        .onChange(of: step) { _, newStep in
            if newStep == .ai, ai.hookOptions.isEmpty {
                Task { await triggerHooksGeneration() }
            }
        }
        .fullScreenCover(isPresented: $showSnapshotCamera) {
            CameraPickerView(isPresented: $showSnapshotCamera) { image in
                guard let image, let session = auth.session else { return }
                let maxSide: CGFloat = 1200
                let scale = min(maxSide / image.size.width, maxSide / image.size.height, 1)
                let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: newSize)
                let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
                guard let data = resized.jpegData(compressionQuality: 0.82) else { return }
                let idx = photoPreviews.count
                photoPreviews.append(resized)
                photoUploadStates.append(.pending)
                enqueueUpload(index: idx, data: data, userId: session.user.id, isSnapshot: true)
            }
        }
    }

    private func restoreDraft(_ draft: OnboardingService.OnboardingDraft) {
        if let n = draft.displayName, !n.isEmpty { name = n }
        if let b = draft.birthdate {
            let parts = b.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3 {
                var comps = DateComponents()
                comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
                if let d = Calendar.current.date(from: comps) { birthDate = d }
            }
        }
        if let g = draft.gender {
            if let gEnum = Gender.allCases.first(where: { $0.rawValue.lowercased() == g.lowercased() }) {
                gender = gEnum
            }
        }
        if let arr = draft.interestedInArr, !arr.isEmpty { interestedIn = arr }
        if let b = draft.bio, !b.isEmpty { bio = b }
        if let c = draft.city, !c.isEmpty { city = c }
        if let km = draft.distanceKm { distanceKm = Double(km) }
        if let mn = draft.ageMin { ageMin = Double(mn) }
        if let mx = draft.ageMax { ageMax = Double(mx) }
        if let lf = draft.lookingFor, !lf.isEmpty {
            lookingFor = Set(lf.split(separator: ",").map { String($0) })
        }
        if let interests = draft.interests {
            selectedInterests = Set(interests.filter { interestOptions.contains($0) })
            selectedKeywords = Set(interests.filter { keywordOptions.contains($0) })
        }
        let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 0
        if age >= 18 { is18 = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Profil einrichten")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                if isDraftSaving {
                    Text("Speichert…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Progress dots
            let contentSteps = Step.allCases
            let currentIndex = contentSteps.firstIndex(of: step) ?? 0
            HStack(spacing: 6) {
                ForEach(0..<contentSteps.count, id: \.self) { i in
                    Capsule()
                        .fill(i <= currentIndex ? brand : Color.gray.opacity(0.25))
                        .frame(width: i == currentIndex ? 24 : 8, height: 8)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: step)
                }
            }
        }
    }

    private var stepTitle: String {
        switch step {
        case .basics: return "Erzähl von dir"
        case .ai: return "Interessen & Bio"
        case .finish: return "Zeig dich von deiner besten Seite"
        }
    }

    private var appBackground: some View {
        LinearGradient(
            colors: [
                brand.opacity(0.14),
                Color.purple.opacity(0.08),
                Color.cyan.opacity(0.06),
                Color(.systemBackground)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Intro Screen

    private var introView: some View {
        ZStack {
            appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo bubble
                ZStack {
                    Circle()
                        .fill(brand.opacity(0.10))
                        .frame(width: 130, height: 130)
                    Circle()
                        .fill(brand.opacity(0.16))
                        .frame(width: 100, height: 100)
                    Image("colored-logo-ohne-schrift")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 60, height: 60)
                }
                .padding(.bottom, 28)

                // Headline
                VStack(spacing: 12) {
                    Text("Kein endloses\nSwipen mehr.")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)

                    Text("Dein persönlicher AI-Wingman findet\nechte Connections – und hilft dir dabei.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .padding(.horizontal, 8)
                }

                Spacer()

                // Feature rows
                VStack(spacing: 10) {
                    introRow(
                        icon: "sparkles",
                        color: brand,
                        title: "AI schreibt mit dir",
                        body: "Bio, Hooks & Icebreaker auf Knopfdruck"
                    )
                    introRow(
                        icon: "heart.fill",
                        color: Color(.sRGB, red: 0xF5/255, green: 0x7C/255, blue: 0x5B/255, opacity: 1),
                        title: "Smarte Matches",
                        body: "Kein Zufall – Leute, die wirklich zu dir passen"
                    )
                    introRow(
                        icon: "bolt.fill",
                        color: Color(.sRGB, red: 1.0, green: 0.70, blue: 0.0, opacity: 1),
                        title: "In 2 Minuten startklar",
                        body: "Kurzes Setup, sofort loslegen"
                    )
                }
                .padding(.horizontal, 24)

                Spacer()

                // CTA
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        showIntro = false
                    }
                    location.request()
                } label: {
                    HStack(spacing: 10) {
                        Text("Profil erstellen")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(.white)
                        Image(systemName: "arrow.right")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(
                        LinearGradient(colors: [brand, brand.opacity(0.82)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: brand.opacity(0.45), radius: 14, y: 7)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 52)
            }
        }
    }

    private func introRow(icon: String, color: Color, title: String, body bodyText: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.12))
                    .frame(width: 46, height: 46)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                Text(bodyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(.systemBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.gray.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .basics:
            basicsView
        case .ai:
            aiView
        case .finish:
            finishView
        }
    }

    // MARK: Slide 1
    private var basicsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("Deine Basics")

            fieldCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "person").frame(width: 22).foregroundStyle(.secondary)
                        Text("Name").font(.subheadline).fontWeight(.semibold)
                    }
                    TextField("Wie sollen wir dich nennen?", text: $name)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .background(Color(.systemBackground))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.gray.opacity(0.22), lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Divider().opacity(0.25)

                Toggle("Ich bin 18 oder älter", isOn: $is18.animation())

                if is18 {
                    Divider().opacity(0.25)
                    FieldRow(title: "Geburtsdatum", subtitle: "", systemImage: "calendar") {
                        DatePicker("", selection: $birthDate, in: ...Date(), displayedComponents: .date)
                            .labelsHidden()
                    }
                }
            }

            sectionTitle("Ich bin")
            tileGrid {
                GenderTile(title: "Mann", icon: "figure.stand", value: .male, selection: $gender, brand: brand)
                GenderTile(title: "Frau", icon: "figure.stand.dress", value: .female, selection: $gender, brand: brand)
                GenderTile(title: "Divers", icon: "person.2.wave.2", value: .diverse, selection: $gender, brand: brand)
                GenderTile(title: "Keine Angabe", icon: "questionmark.circle", value: .none, selection: $gender, brand: brand)
            }

            sectionTitle("Ich möchte sehen")
            tileGrid {
                InterestedTile(title: "Frauen", icon: "figure.stand.dress", selected: interestedIn.contains("women"), brand: brand) { toggleInterested("women") }
                InterestedTile(title: "Männer", icon: "figure.stand", selected: interestedIn.contains("men"), brand: brand) { toggleInterested("men") }
                InterestedTile(title: "Divers", icon: "person.2.wave.2", selected: interestedIn.contains("divers"), brand: brand) { toggleInterested("divers") }
                InterestedTile(title: "Alle", icon: "heart.fill", selected: interestedIn.contains("all"), brand: brand) { toggleInterested("all") }
            }

            sectionTitle("Ich suche")
            tileGrid {
                InterestedTile(title: "Etwas Ernstes", icon: "heart.fill", selected: lookingFor.contains("serious"), brand: brand) { toggleLookingFor("serious") }
                InterestedTile(title: "Etwas Lockeres", icon: "sparkles", selected: lookingFor.contains("casual"), brand: brand) { toggleLookingFor("casual") }
                InterestedTile(title: "Neue Freunde", icon: "person.2.fill", selected: lookingFor.contains("friends"), brand: brand) { toggleLookingFor("friends") }
                InterestedTile(title: "Bin offen", icon: "infinity", selected: lookingFor.contains("open_to_all"), brand: brand) { toggleLookingFor("open_to_all") }
            }

            sectionTitle("Dein Standort")
            fieldCard {
                if location.isWorking {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Suche Standort…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
                } else if location.isAuthorized, let locCity = location.city, !locCity.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill").foregroundStyle(brand)
                        Text(locCity).fontWeight(.semibold)
                        Spacer()
                        Button("Aktualisieren") { location.request() }
                            .font(.footnote).tint(brand)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Stadt eingeben", text: $city)
                            .textInputAutocapitalization(.words)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(Color(.systemBackground))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.22), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        Button { location.request() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "location.fill").font(.caption)
                                Text("Standort automatisch erkennen").font(.caption.weight(.medium))
                            }
                            .foregroundStyle(brand)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onChange(of: name) { _, _ in scheduleDraftSave() }
        .onChange(of: birthDate) { _, _ in applyDefaultAgeRange(); scheduleDraftSave() }
        .onChange(of: is18) { _, newValue in if newValue { applyDefaultAgeRange() }; scheduleDraftSave() }
        .onChange(of: gender) { _, _ in scheduleDraftSave() }
        .onChange(of: interestedIn) { _, _ in scheduleDraftSave() }
        .onChange(of: lookingFor) { _, _ in scheduleDraftSave() }
        .onChange(of: city) { _, _ in scheduleDraftSave() }
        .onChange(of: location.city) { _, newValue in
            if let newValue, !newValue.isEmpty { city = newValue }
        }
    }

    // MARK: Slide 2
    private var aiView: some View {
        VStack(alignment: .leading, spacing: 28) {

            // Interests (3–6) — required
            sectionTitle("Deine Interessen")
            Text("Wähle 3–6 Dinge, die dich ausmachen.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            softChipWrap {
                ForEach(interestOptions, id: \.self) { it in
                    SoftChip(
                        title: it,
                        selected: selectedInterests.contains(it),
                        disabled: !selectedInterests.contains(it) && selectedInterests.count >= maxInterestsSelected
                    ) {
                        if selectedInterests.contains(it) {
                            selectedInterests.remove(it)
                        } else {
                            guard selectedInterests.count < maxInterestsSelected else {
                                showLimitHint("Max. \(maxInterestsSelected) Interessen")
                                return
                            }
                            selectedInterests.insert(it)
                        }
                    }
                }
            }
            Divider().padding(.top, 12)
            // Keywords — optional
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Drei Wörter über dich")
                Spacer()
                Text("Optional")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())
            }
            Text("Bis zu 3 Wörter, die dich beschreiben.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            softChipWrap {
                ForEach(keywordOptions, id: \.self) { kw in
                    SoftChip(
                        title: kw,
                        selected: selectedKeywords.contains(kw),
                        disabled: !selectedKeywords.contains(kw) && selectedKeywords.count >= keywordsMustSelect
                    ) {
                        if selectedKeywords.contains(kw) {
                            selectedKeywords.remove(kw)
                        } else {
                            guard selectedKeywords.count < keywordsMustSelect else {
                                showLimitHint("Max. \(keywordsMustSelect) Wörter")
                                return
                            }
                            selectedKeywords.insert(kw)
                        }
                    }
                }
            }

            if let hint = limitHint {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            }

            Divider()
            sectionTitle("Deine Bio")

            fieldCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Erzähl, wer du bist")
                            .font(.subheadline.weight(.semibold))
                        Text("Deine Bio ist dein erster Eindruck.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    aiPillButton(title: "AI-Wingman", isLoading: ai.bioLoading) {
                        showBioAIDirection = true
                    }
                }

                TextEditor(text: $bio)
                    .frame(height: 140)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.gray.opacity(0.25)))
            }

            Divider()

            // Gesprächsstarter (Hooks)
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Gesprächsstarter")
                Spacer()
                aiPillButton(title: "Neu", isLoading: ai.hooksLoading) {
                    Task { await triggerHooksGeneration() }
                }
            }
            Text("Wähle bis zu 3 – sie erscheinen auf deinem Profil und geben anderen einen Gesprächseinstieg.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if ai.hooksLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.75)
                    Text("KI erstellt Vorschläge…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if !ai.hookOptions.isEmpty {
                softChipWrap {
                    ForEach(ai.hookOptions, id: \.self) { hook in
                        HookChip(
                            title: hook,
                            selected: ai.selectedHooks.contains(hook),
                            disabled: !ai.selectedHooks.contains(hook) && ai.selectedHooks.count >= 3
                        ) {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if ai.selectedHooks.contains(hook) {
                                ai.selectedHooks.remove(hook)
                            } else if ai.selectedHooks.count < 3 {
                                ai.selectedHooks.insert(hook)
                            }
                        }
                    }
                }
                if ai.selectedHooks.count > 0 {
                    Text("\(ai.selectedHooks.count)/3 ausgewählt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // First Date Vibes
            sectionTitle("First Date Vibes")
            Text("Was für ein Date magst du? Optional – hilft anderen zu sehen, was dich anspricht.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !ai.vibeOptions.isEmpty {
                softChipWrap {
                    ForEach(ai.vibeOptions, id: \.self) { vibe in
                        SoftChip(
                            title: vibe,
                            selected: ai.selectedVibes.contains(vibe)
                        ) {
                            if ai.selectedVibes.contains(vibe) {
                                ai.selectedVibes.remove(vibe)
                            } else {
                                ai.selectedVibes.insert(vibe)
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: selectedInterests) { _, _ in scheduleDraftSave() }
        .onChange(of: selectedKeywords) { _, _ in scheduleDraftSave() }
        .onChange(of: bio) { _, _ in scheduleDraftSave() }
    }

    // MARK: Slide 3 (Photos)
    private var finishView: some View {
        VStack(alignment: .leading, spacing: 18) {

            // Motivating header
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(brand.opacity(0.12))
                        .frame(width: 46, height: 46)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(brand)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Zeig, wer du bist")
                        .font(.system(.headline, design: .rounded))
                    Text("Echte Fotos = echte Matches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(Color(.systemBackground).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.gray.opacity(0.12), lineWidth: 1))

            // Compact tips
            VStack(alignment: .leading, spacing: 8) {
                photoTipRow("Klares Gesichtsfoto als erstes Bild")
                photoTipRow("Tageslicht wirkt am natürlichsten")
                photoTipRow("Zeig Persönlichkeit – Hobbys, Orte, Vibes")
            }
            .padding(14)
            .background(brand.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(brand.opacity(0.15), lineWidth: 1))

            fieldCard {
                HStack {
                    Text("Fotos").font(.headline)
                    Spacer()
                    Text("\(photoPreviews.count)/6").font(.footnote).foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(Array(photoPreviews.enumerated()), id: \.offset) { idx, img in
                        ZStack(alignment: .topTrailing) {
                            Button { Task { await setPrimaryPhoto(index: idx) } } label: {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(height: 110)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .stroke(idx == primaryPhotoIndex ? brand.opacity(0.75) : Color.gray.opacity(0.18),
                                                    lineWidth: idx == primaryPhotoIndex ? 2 : 1)
                                    )
                                    .shadow(color: idx == primaryPhotoIndex ? .black.opacity(0.12) : .clear, radius: 8, y: 4)
                                    .clipped()
                            }
                            .buttonStyle(.plain)

                            Button { Task { await removePhoto(at: idx) } } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .padding(8)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                            .accessibilityLabel("Foto entfernen")
                            .padding(6)

                            // Upload state badge + retry
                            if photoUploadStates.indices.contains(idx) {
                                switch photoUploadStates[idx] {
                                case .pending:
                                    stateBadge(text: "Wartet")
                                case .uploading:
                                    stateBadge(text: "Upload")
                                case .done:
                                    EmptyView()
                                case .failed:
                                    VStack(alignment: .trailing, spacing: 6) {
                                        stateBadge(text: "Fehler")
                                        Button {
                                            retryUpload(at: idx)
                                        } label: {
                                            Text("Wiederholen")
                                                .font(.caption)
                                                .fontWeight(.semibold)
                                                .padding(.vertical, 6)
                                                .padding(.horizontal, 10)
                                                .background(.ultraThinMaterial)
                                                .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    if photoPreviews.count < 6 {
                        PhotosPicker(selection: $photoItems, maxSelectionCount: 6, matching: .images) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.black.opacity(0.03))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.gray.opacity(0.18), lineWidth: 1))
                                VStack(spacing: 8) {
                                    Image(systemName: "plus").font(.title3).foregroundStyle(brand)
                                    Text("Galerie").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .frame(height: 110)
                        }
                        .buttonStyle(.plain)

                        Button { showSnapshotCamera = true } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(brand.opacity(0.07))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(brand.opacity(0.2), lineWidth: 1))
                                VStack(spacing: 8) {
                                    Image(systemName: "camera.fill").font(.title3).foregroundStyle(brand)
                                    Text("Selfie").font(.footnote).foregroundStyle(brand)
                                }
                            }
                            .frame(height: 110)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if isUploadingPhoto {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(uploadStatusText ?? "Upload läuft…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Bottom bar + helpers
    private var currentStepError: String? {
        validate(step)
    }

    private var canContinue: Bool {
        if isBusy { return false }
        if step == .finish { return currentStepError == nil && pendingUploadCount == 0 }
        return currentStepError == nil
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let msg = currentStepError {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if step.rawValue > Step.basics.rawValue {
                    Button("Zurück") {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        stepForward = false
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            step = Step(rawValue: step.rawValue - 1) ?? .basics
                        }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Spacer().frame(width: 1)
                }

                Spacer()

                PrimaryGradientButton(
                    title: step == .finish
                        ? (isBusy ? "Speichern…" : (pendingUploadCount > 0 ? "Uploads…" : "Fertig"))
                        : "Weiter",
                    brand: brand,
                    isDisabled: !canContinue
                ) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if step != .finish {
                        stepForward = true
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            step = Step(rawValue: step.rawValue + 1) ?? .finish
                        }
                    } else {
                        Task { await finish() }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.gray.opacity(0.18)), alignment: .top)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline).padding(.top, 2)
    }

    private func fieldCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(14)
            .background(Color(.systemBackground).opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.gray.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    }

    private func tileGrid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) { content() }
    }

private func softChipWrap<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    FlowWrapLayout(spacing: 12, rowSpacing: 12) {
        content()
    }
}

    private struct FlowWrapLayout<Content: View>: View {
        let spacing: CGFloat
        let rowSpacing: CGFloat
        @ViewBuilder var content: Content

        init(spacing: CGFloat = 10, rowSpacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
            self.spacing = spacing
            self.rowSpacing = rowSpacing
            self.content = content()
        }

        var body: some View {
            _FlowWrap(spacing: spacing, rowSpacing: rowSpacing) {
                content
            }
        }
    }

    private struct _FlowWrap: Layout {
        let spacing: CGFloat
        let rowSpacing: CGFloat

        init(spacing: CGFloat = 10, rowSpacing: CGFloat = 10) {
            self.spacing = spacing
            self.rowSpacing = rowSpacing
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let maxW = proposal.width ?? 0
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowH: CGFloat = 0

            for s in subviews {
                let natural = s.sizeThatFits(.unspecified)
                let chipW = min(natural.width, maxW)
                let chipH = natural.width > maxW
                    ? s.sizeThatFits(ProposedViewSize(width: maxW, height: nil)).height
                    : natural.height

                if x > 0, x + chipW > maxW {
                    x = 0
                    y += rowH + rowSpacing
                    rowH = 0
                }
                x += chipW + spacing
                rowH = max(rowH, chipH)
            }

            return CGSize(width: maxW, height: y + rowH)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let maxW = bounds.width
            var x = bounds.minX
            var y = bounds.minY
            var rowH: CGFloat = 0

            for s in subviews {
                let natural = s.sizeThatFits(.unspecified)
                let chipW = min(natural.width, maxW)
                let chipH = natural.width > maxW
                    ? s.sizeThatFits(ProposedViewSize(width: maxW, height: nil)).height
                    : natural.height

                if x > bounds.minX, x + chipW > bounds.maxX {
                    x = bounds.minX
                    y += rowH + rowSpacing
                    rowH = 0
                }

                s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: chipW, height: chipH))
                x += chipW + spacing
                rowH = max(rowH, chipH)
            }
        }
    }

    private func checklistRow(icon: String, text: String, required: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(brand)
                .frame(width: 22)
            HStack(spacing: 6) {
                Text(text).font(.subheadline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                if required {
                    Text("*").font(.subheadline).fontWeight(.bold).foregroundStyle(.red).padding(.top, 1)
                }
            }
            Spacer()
        }
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(brand).frame(width: 6, height: 6).padding(.top, 6)
            Text(text).font(.subheadline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func photoTipRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(brand)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private func triggerHooksGeneration() async {
        guard !ai.hooksLoading else { return }
        await ai.generateHooks(input: HooksInput(
            gender: genderLabelDE(),
            interestedIn: interestedInDE(),
            city: city.trimmed.isEmpty ? nil : city.trimmed,
            lookingFor: lookingFor.isEmpty ? nil : lookingFor.sorted().joined(separator: ","),
            bio: bio.trimmed.isEmpty ? nil : bio.trimmed,
            interests: Array(selectedInterests),
            promptAnswers: nil,
            maxHooks: 8,
            maxVibes: 8
        ))
    }

    private func aiPillButton(title: String, isLoading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.subheadline)
                Text(isLoading ? "AI…" : title).font(.subheadline).fontWeight(.semibold)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                LinearGradient(
                    colors: [brand.opacity(0.22), Color.purple.opacity(0.20), Color.cyan.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(Capsule())
            .overlay(Capsule().stroke(brand.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isLoading)
    }

    private func showLimitHint(_ text: String) {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.impactOccurred()
        limitHint = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            if limitHint == text { limitHint = nil }
        }
    }
    private func scheduleDraftSave() {
        if isBusy { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            await saveDraftSilently()
        }
    }

    private func interestsForStorage() -> [String] {
        // damit Resume funktioniert, speichern wir Interests + 3 Wörter zusammen
        Array(selectedInterests) + Array(selectedKeywords)
    }

    private func safeGenderRaw() -> String? {
        (gender == .male || gender == .female || gender == .diverse) ? gender.rawValue : nil
    }

    /// German gender string for AI prompts (gendered German output requires German terms).
    private func genderLabelDE() -> String? {
        switch gender {
        case .male:    return "männlich"
        case .female:  return "weiblich"
        case .diverse: return "divers"
        default:       return nil
        }
    }

    /// German labels for interestedIn array, for AI context.
    private func interestedInDE() -> [String]? {
        guard !interestedIn.isEmpty else { return nil }
        let map: [String: String] = ["women": "Frauen", "men": "Männer", "divers": "Divers", "all": "Alle"]
        return interestedIn.compactMap { map[$0] }
    }

    private func safeLookingForRaw() -> String {
        lookingFor.isEmpty ? "not_sure" : lookingFor.sorted().joined(separator: ",")
    }

    private func interestedInArrForStorage() -> [String]? {
        if interestedIn.contains("all") {
            return ["women", "men", "divers"]
        }
        let cleaned = interestedIn
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { ["women", "men", "divers"].contains($0) }

        let unique = Array(Set(cleaned)).sorted()
        return unique.isEmpty ? nil : unique
    }

    private func canAutosaveDraft() -> Bool {
        !name.trimmed.isEmpty || !city.trimmed.isEmpty || !selectedInterests.isEmpty || !selectedKeywords.isEmpty || !bio.trimmed.isEmpty
    }

    private func saveDraftSilently() async {
        guard let session = auth.session else { return }
        guard canAutosaveDraft() else { return }
        if isDraftSaving { return }

        isDraftSaving = true
        defer { isDraftSaving = false }

        do {
            try await OnboardingService.shared.upsertProfileDraft(
                userId: session.user.id,
                displayName: name,
                birthdate: birthDate,
                gender: safeGenderRaw(),
                interestedInArr: interestedInArrForStorage(),
                bio: bio,
                city: city,
                interests: interestsForStorage(),
                distanceKm: Int(distanceKm),
                ageMin: Int(ageMin),
                ageMax: Int(ageMax),
                lookingFor: lookingFor.isEmpty ? nil : lookingFor.sorted().joined(separator: ","),
                hooks: ai.selectedHooks.isEmpty ? nil : Array(ai.selectedHooks).sorted(),
                firstDateVibes: ai.selectedVibes.isEmpty ? nil : Array(ai.selectedVibes).sorted(),
                prompt1: nil, answer1: nil,
                prompt2: nil, answer2: nil,
                prompt3: nil, answer3: nil
            )
        } catch {
            // silent
        }
    }
    private func toggleInterested(_ key: String) {
        // supported: women/men/divers/all
        guard ["women", "men", "divers", "all"].contains(key) else { return }

        if key == "all" {
            if interestedIn.contains("all") { interestedIn.removeAll() }
            else { interestedIn = ["all"] }
            return
        }

        // selecting any specific group removes "all"
        interestedIn.removeAll { $0 == "all" }

        if interestedIn.contains(key) {
            interestedIn.removeAll { $0 == key }
        } else {
            interestedIn.append(key)
        }
    }

    private func toggleLookingFor(_ key: String) {
        if lookingFor.contains(key) {
            lookingFor.remove(key)
        } else {
            lookingFor = [key] // single-select: replaces previous choice
        }
    }

    private var currentUserAge: Int {
        Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 0
    }

    private var ageMinRange: ClosedRange<Double> {
        (!ageRangeUnlocked && currentUserAge >= 36) ? 30...55 : 18...55
    }

    private var ageMaxRange: ClosedRange<Double> {
        (!ageRangeUnlocked && currentUserAge <= 27) ? 18...30 : 18...55
    }

    private func applyDefaultAgeRange() {
        guard is18 else { return }
        ageRangeUnlocked = false
        let age = currentUserAge
        if age <= 27 {
            ageMin = 18; ageMax = 30
        } else if age <= 35 {
            ageMin = 18; ageMax = 55
        } else {
            ageMin = 30; ageMax = 55
        }
    }

    private func validate(_ step: Step) -> String? {
        switch step {
        case .basics:
            if !is18 { return "18+ erforderlich." }
            if name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 { return "Name zu kurz." }
            if gender == .unset { return "Bitte wähle ein Geschlecht." }
            if interestedIn.isEmpty { return "Bitte wähle, wen du sehen möchtest." }
            if lookingFor.isEmpty { return "Bitte wähle, was du suchst." }
            if city.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 { return "Stadt fehlt." }
            return nil

        case .ai:
            if selectedInterests.count < minInterestsSelected || selectedInterests.count > maxInterestsSelected {
                return "Bitte \(minInterestsSelected)–\(maxInterestsSelected) Interessen wählen."
            }
            if bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Deine Bio fehlt – sie ist dein erster Eindruck." }
            if bio.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 { return "Bio ist zu kurz – schreib ein bisschen mehr." }
            return nil

        case .finish:
            if photoUrls.isEmpty { return "Bitte mindestens 1 Foto hochladen." }
            return nil
        }
    }

    private func finish() async {
        guard let session = auth.session else { return }
        isBusy = true
        defer { isBusy = false }

        if let msg = validate(.basics) ?? validate(.ai) ?? validate(.finish) {
            error = msg
            return
        }

        do {
            try await OnboardingService.shared.upsertProfileDraft(
                userId: session.user.id,
                displayName: name,
                birthdate: birthDate,
                gender: (gender == .male || gender == .female || gender == .diverse) ? gender.rawValue : nil,
                interestedInArr: interestedInArrForStorage(),
                bio: bio,
                city: city,
                interests: Array(selectedInterests),
                distanceKm: Int(distanceKm),
                ageMin: Int(ageMin), ageMax: Int(ageMax),
                lookingFor: lookingFor.isEmpty ? nil : lookingFor.sorted().joined(separator: ","),
                hooks: ai.selectedHooks.isEmpty ? nil : Array(ai.selectedHooks).sorted(),
                firstDateVibes: ai.selectedVibes.isEmpty ? nil : Array(ai.selectedVibes).sorted(),
                prompt1: nil, answer1: nil,
                prompt2: nil, answer2: nil,
                prompt3: nil, answer3: nil
            )

            if let lat = location.latitude, let lng = location.longitude {
                _ = try? await SupabaseClientProvider.shared.client
                    .from("profiles")
                    .update(["location_lat": lat, "location_lng": lng])
                    .eq("user_id", value: session.user.id.uuidString)
                    .execute()
            }

            try await OnboardingService.shared.setOnboardingComplete(userId: session.user.id, complete: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { showCompletion = true }
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            onFinished()
        } catch {
            self.error = error.localizedDescription
        }
    }
        private func compressJPEG(_ image: UIImage) -> Data? {
            let maxSide: CGFloat = 1600
            let size = image.size
            let scale = min(1.0, maxSide / max(size.width, size.height))

            if scale < 1.0 {
                let newSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
                let renderer = UIGraphicsImageRenderer(size: newSize)
                let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
                return resized.jpegData(compressionQuality: 0.82)
            }
            return image.jpegData(compressionQuality: 0.82)
        }

    private var pendingUploadCount: Int {
        photoUploadStates.filter {
            switch $0 {
            case .pending, .uploading, .failed: return true
            case .done: return false
            }
        }.count
    }

    private func enqueueUpload(index: Int, data: Data, userId: UUID, isSnapshot: Bool = false) {
        uploadQueue.append((index: index, data: data, userId: userId, isSnapshot: isSnapshot))
        startUploadWorkerIfNeeded()
    }

    private func startUploadWorkerIfNeeded() {
        guard !uploadWorkerRunning else { return }
        uploadWorkerRunning = true
        isUploadingPhoto = true

        Task {
            while !uploadQueue.isEmpty {
                let job = uploadQueue.removeFirst()
                await MainActor.run {
                    if photoUploadStates.indices.contains(job.index) {
                        photoUploadStates[job.index] = .uploading
                    }
                    let total = max(photoPreviews.count, photoUploadStates.count)
                    uploadStatusText = "Upload \(min(job.index + 1, total))/\(total)…"
                }

                do {
                    try await uploadPhotoDataThrowing(job.data, userId: job.userId, localIndex: job.index, isSnapshot: job.isSnapshot)
                    await MainActor.run {
                        if photoUploadStates.indices.contains(job.index) {
                            photoUploadStates[job.index] = .done
                        }
                    }
                } catch {
                    await MainActor.run {
                        if photoUploadStates.indices.contains(job.index) {
                            photoUploadStates[job.index] = .failed(error.localizedDescription)
                        }
                    }
                }
            }

            await MainActor.run {
                uploadWorkerRunning = false
                isUploadingPhoto = false
                uploadStatusText = nil
            }
        }
    }

    private func retryUpload(at index: Int) {
        guard let session = auth.session else { return }
        guard photoPreviews.indices.contains(index) else { return }
        if photoUploadStates.indices.contains(index) {
            photoUploadStates[index] = .pending
        }
        let data = compressJPEG(photoPreviews[index]) ?? (photoPreviews[index].jpegData(compressionQuality: 0.85) ?? Data())
        if !data.isEmpty {
            enqueueUpload(index: index, data: data, userId: session.user.id)
        }
    }

    private func uploadPhotoDataThrowing(_ data: Data, userId: UUID, localIndex: Int, isSnapshot: Bool = false) async throws {
        let bucket = "profile-photos"
        let path = "\(userId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        let accessToken = auth.session?.accessToken ?? ""

        try await uploadToStorageRawHTTP(
            bucket: bucket,
            path: path,
            data: data,
            contentType: "image/jpeg",
            upsert: true,
            accessToken: accessToken
        )

        let client = SupabaseClientProvider.shared.client
        let publicUrl = try client.storage.from(bucket).getPublicURL(path: path)
        let urlString = publicUrl.absoluteString

        struct PhotoInsert: Encodable {
            let user_id: UUID
            let url: String
            let sort_order: Int
            let is_primary: Bool
            let is_snapshot: Bool
        }

        // Use current photo count as sort order — unique per sequential upload
        let sortOrder = photoUrls.count
        let makePrimary = !isSnapshot && sortOrder == 0

        if makePrimary {
            _ = try? await client
                .from("photos")
                .update(["is_primary": false])
                .eq("user_id", value: userId.uuidString)
                .execute()
        }

        _ = try await client
            .from("photos")
            .insert(PhotoInsert(user_id: userId, url: urlString, sort_order: sortOrder, is_primary: makePrimary, is_snapshot: isSnapshot))
            .execute()

        await MainActor.run {
            self.photoUrls.append(urlString)
            if makePrimary { self.primaryPhotoIndex = 0 }
        }
    }

    private func uploadPhotoData(_ data: Data, userId: UUID) async {
        do {
            try await uploadPhotoDataThrowing(data, userId: userId, localIndex: max(0, photoPreviews.count - 1))
        } catch {
            await MainActor.run {
                self.error = "Foto-Upload fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
    private func stateBadge(text: String) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(6)
    }

    private func setPrimaryPhoto(index: Int) async {
        guard index >= 0, index < photoUrls.count else { return }
        guard let session = auth.session else { return }
        let userId = session.user.id
        let url = photoUrls[index]

        primaryPhotoIndex = index

        let client = SupabaseClientProvider.shared.client
        _ = try? await client
            .from("photos")
            .update(["is_primary": false])
            .eq("user_id", value: userId.uuidString)
            .execute()

        _ = try? await client
            .from("photos")
            .update(["is_primary": true])
            .eq("user_id", value: userId.uuidString)
            .eq("url", value: url)
            .execute()
    }

    private func removePhoto(at index: Int) async {
        guard index >= 0, index < photoPreviews.count else { return }
        let removedUrl: String? = (index < photoUrls.count) ? photoUrls[index] : nil

        await MainActor.run {
            photoPreviews.remove(at: index)
            if index < photoUrls.count { photoUrls.remove(at: index) }
            if index < photoItems.count { photoItems.remove(at: index) }
            if primaryPhotoIndex == index { primaryPhotoIndex = 0 }
            else if primaryPhotoIndex > index { primaryPhotoIndex -= 1 }
        }

        guard let url = removedUrl, let session = auth.session else { return }
        let client = SupabaseClientProvider.shared.client
        _ = try? await client
            .from("photos")
            .delete()
            .eq("user_id", value: session.user.id.uuidString)
            .eq("url", value: url)
            .execute()

        if !photoUrls.isEmpty { await setPrimaryPhoto(index: primaryPhotoIndex) }
    }

    private func uploadToStorageRawHTTP(
        bucket: String,
        path: String,
        data: Data,
        contentType: String,
        upsert: Bool,
        accessToken: String
    ) async throws {
        let url = SupabaseClientProvider.shared.supabaseURL
            .appendingPathComponent("storage/v1/object/\(bucket)/\(path)")
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue(SupabaseClientProvider.shared.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue(upsert ? "true" : "false", forHTTPHeaderField: "x-upsert")
        
        req.timeoutInterval = 30
        
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 45
        let session = URLSession(configuration: cfg)
        
        let (respData, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: respData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "StorageUpload",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Upload fehlgeschlagen (\(http.statusCode)). \(body)"]
            )
        }
    }
}

// MARK: Supporting types
private enum Gender: String, CaseIterable, Identifiable {
    case unset, male, female, diverse, none
    var id: String { rawValue }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var city: String? = nil
    @Published var latitude: Double? = nil
    @Published var longitude: Double? = nil
    @Published var errorText: String? = nil
    @Published var isWorking: Bool = false
    @Published var isAuthorized: Bool = false

    private var didStartLocationRequest = false
    private var activeRequestId: UUID? = nil
    private let manager = CLLocationManager()

    @available(iOS 26.0, *)
    private func reverseGeocodeCity_iOS26(_ loc: CLLocation) async throws -> String? {
        guard let request = MKReverseGeocodingRequest(location: loc) else { throw MKError(.decodingFailed) }
        let items = try await request.mapItems
        let addr = items.first?.addressRepresentations
        return addr?.cityName ?? addr?.regionName
    }

    @available(iOS, deprecated: 26.0)
    private func reverseGeocodeCity_legacy(_ loc: CLLocation) async throws -> String? {
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.reverseGeocodeLocation(loc)
        let pm = placemarks.first
        return pm?.locality ?? pm?.subAdministrativeArea ?? pm?.administrativeArea
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let s = manager.authorizationStatus
        isAuthorized = s == .authorizedWhenInUse || s == .authorizedAlways
    }

    func request() {
        if isWorking { return }
        errorText = nil
        isWorking = true
        didStartLocationRequest = false
        let rid = UUID()
        activeRequestId = rid

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard self.activeRequestId == rid, self.isWorking else { return }
            self.isWorking = false
            self.errorText = "Standort dauert zu lange. Prüfe GPS/Simulator-Location und versuch’s nochmal."
        }

        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .restricted, .denied:
            isWorking = false
            errorText = "Standort ist deaktiviert. Bitte in iOS Einstellungen erlauben."
        case .authorizedAlways, .authorizedWhenInUse:
            didStartLocationRequest = true
            manager.requestLocation()
        @unknown default:
            isWorking = false
            errorText = "Unbekannter Standort-Status."
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        isAuthorized = status == .authorizedWhenInUse || status == .authorizedAlways
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            if isWorking && !didStartLocationRequest {
                didStartLocationRequest = true
                manager.requestLocation()
            }
        } else if status == .denied || status == .restricted {
            isWorking = false
            errorText = "Standort wurde nicht erlaubt."
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        didStartLocationRequest = false
        activeRequestId = nil
        isWorking = false
        errorText = "Standort fehlgeschlagen: \(error.localizedDescription)"
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else {
            isWorking = false
            errorText = "Kein Standort gefunden."
            return
        }

        latitude = loc.coordinate.latitude
        longitude = loc.coordinate.longitude

        Task {
            do {
                if #available(iOS 26.0, *) {
                    let foundCity = try await reverseGeocodeCity_iOS26(loc)
                    if let foundCity, !foundCity.isEmpty { self.city = foundCity }
                } else {
                    let foundCity = try await reverseGeocodeCity_legacy(loc)
                    if let foundCity, !foundCity.isEmpty { self.city = foundCity }
                }
                self.didStartLocationRequest = false
                self.activeRequestId = nil
                self.isWorking = false
            } catch {
                self.didStartLocationRequest = false
                self.activeRequestId = nil
                self.isWorking = false
                self.errorText = "Reverse Geocoding fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Age Range Slider

private struct AgeRangeSlider: View {
    @Binding var low: Double
    @Binding var high: Double
    /// Full visible track range (always 18...55)
    let range: ClosedRange<Double>
    /// Physical limits per thumb — enforced during drag
    let lowRange: ClosedRange<Double>
    let highRange: ClosedRange<Double>
    let step: Double
    let brand: Color

    private let trackH: CGFloat = 4
    private let thumbD: CGFloat = 26

    private func frac(_ val: Double) -> CGFloat {
        CGFloat((val - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private func snapped(_ x: CGFloat, width: CGFloat) -> Double {
        let clamped = max(0, min(CGFloat(1), x / width))
        let raw = range.lowerBound + Double(clamped) * (range.upperBound - range.lowerBound)
        return (raw / step).rounded() * step
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let lowX  = frac(low)  * w
            let highX = frac(high) * w

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemGray5))
                    .frame(height: trackH)

                Capsule()
                    .fill(brand)
                    .frame(width: max(0, highX - lowX), height: trackH)
                    .offset(x: lowX)

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbD, height: thumbD)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .offset(x: lowX - thumbD / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("ageSlider"))
                            .onChanged { v in
                                let raw = snapped(v.location.x, width: w)
                                low = max(lowRange.lowerBound, min(raw, min(high, lowRange.upperBound)))
                            }
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbD, height: thumbD)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .offset(x: highX - thumbD / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("ageSlider"))
                            .onChanged { v in
                                let raw = snapped(v.location.x, width: w)
                                high = min(highRange.upperBound, max(raw, max(low, highRange.lowerBound)))
                            }
                    )
            }
            .frame(height: thumbD)
        }
        .frame(height: thumbD)
        .coordinateSpace(name: "ageSlider")
    }
}

private struct FieldRow<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage).frame(width: 22).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.semibold)
                if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()
            content
        }
    }
}

private struct SoftChip: View {
    let title: String
    let selected: Bool
    let disabled: Bool
    let action: () -> Void

    init(title: String, selected: Bool, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        let h = abs(title.hashValue)
        let rot = Double((h % 7) - 3) * 0.14 // much subtler
        let padV = CGFloat(8 + (h % 2))      // 8..9
        let padH = CGFloat(12 + (h % 4))     // 12..15

        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, padV)
                .padding(.horizontal, padH)
                .frame(minHeight: 44) // iOS tap target
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .foregroundStyle(selected ? .white : .primary)
        .background(
            Capsule()
                .fill(
                    selected
                    ? LinearGradient(
                        colors: [
                            Color(.sRGB, red: 0xE8/255.0, green: 0x60/255.0, blue: 0x7A/255.0, opacity: 0.95),
                            Color(.sRGB, red: 0xE8/255.0, green: 0x60/255.0, blue: 0x7A/255.0, opacity: 0.78)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    : LinearGradient(
                        colors: [Color(.systemGray6), Color(.systemGray5).opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .rotationEffect(.degrees(rot)) // visual only
        )
        .overlay(
            Capsule()
                .stroke(selected ? Color.white.opacity(0.20) : Color.gray.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: selected ? .black.opacity(0.10) : .black.opacity(0.02), radius: selected ? 7 : 4, y: selected ? 3 : 2)
        .opacity(disabled ? 0.45 : 1.0)
        .disabled(disabled)
        .animation(.easeInOut(duration: 0.14), value: selected)
    }
}

private struct HookChip: View {
    let title: String
    let selected: Bool
    let disabled: Bool
    let action: () -> Void

    init(title: String, selected: Bool, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .white : .primary)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(selected ? Color(.sRGB, red: 0xE8/255.0, green: 0x60/255.0, blue: 0x7A/255.0, opacity: 1.0)
                       : Color(.systemGray6))
        )
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.clear : Color.gray.opacity(0.22), lineWidth: 1))
        .shadow(color: selected ? .black.opacity(0.10) : .clear, radius: 8, y: 4)
        .opacity(disabled ? 0.45 : 1.0)
        .disabled(disabled)
    }
}

private struct InterestedTile: View {
    let title: String
    let icon: String
    let selected: Bool
    let brand: Color
    let onTap: () -> Void

    private let brandAlt = Color(.sRGB, red: 0xF5/255, green: 0x7C/255, blue: 0x5B/255, opacity: 1)

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTap()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(selected ? .white : brand)
                    .scaleEffect(selected ? 1.15 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selected)
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(selected ? .white : .primary)
            }
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(
                Group {
                    if selected {
                        LinearGradient(colors: [brand, brandAlt], startPoint: .topLeading, endPoint: .bottomTrailing)
                    } else {
                        LinearGradient(colors: [Color(.systemBackground).opacity(0.95), Color(.systemBackground).opacity(0.95)], startPoint: .top, endPoint: .bottom)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(selected ? Color.clear : Color.gray.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: selected ? brand.opacity(0.35) : .black.opacity(0.04), radius: selected ? 12 : 4, y: selected ? 6 : 2)
            .scaleEffect(selected ? 1.04 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: selected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Completion Overlay

// MARK: - Floating heart particle

private struct FloatingHeart: Identifiable {
    let id = UUID()
    let startX: CGFloat
    let size: CGFloat
    let color: Color
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var opacity: Double = 0
    var scale: CGFloat = 0.3
}

extension OnboardingView {
    var completionOverlay: some View {
        CompletionView(brand: brand)
    }
}

private struct CompletionView: View {
    let brand: Color
    let brandAlt = Color(.sRGB, red: 0xF5/255, green: 0x7C/255, blue: 0x5B/255, opacity: 1)

    @State private var hearts: [FloatingHeart] = []
    @State private var logoScale: CGFloat = 0.1
    @State private var logoOpacity: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var textOffset: CGFloat = 30
    @State private var textOpacity: Double = 0

    private let heartColors: [Color] = [
        Color(.sRGB, red: 0xE8/255, green: 0x60/255, blue: 0x7A/255, opacity: 1),
        Color(.sRGB, red: 0xF5/255, green: 0x7C/255, blue: 0x5B/255, opacity: 1),
        .pink, Color(.sRGB, red: 0xFF/255, green: 0xB3/255, blue: 0xC6/255, opacity: 1),
        .purple.opacity(0.8)
    ]

    var body: some View {
        ZStack {
            // Warm gradient bg
            LinearGradient(
                colors: [brand.opacity(0.18), brandAlt.opacity(0.10), Color(.systemBackground)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // Floating hearts
            GeometryReader { geo in
                ForEach(hearts) { h in
                    Image(systemName: "heart.fill")
                        .font(.system(size: h.size))
                        .foregroundStyle(h.color)
                        .position(x: h.startX + h.offsetX, y: geo.size.height * 0.65 + h.offsetY)
                        .opacity(h.opacity)
                        .scaleEffect(h.scale)
                }
            }

            VStack(spacing: 32) {
                // Pulsing logo
                ZStack {
                    Circle()
                        .fill(brand.opacity(0.08))
                        .frame(width: 160, height: 160)
                        .scaleEffect(pulseScale)
                    Circle()
                        .fill(brand.opacity(0.14))
                        .frame(width: 130, height: 130)
                    Image("colored-logo-ohne-schrift")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                }
                .scaleEffect(logoScale)
                .opacity(logoOpacity)

                VStack(spacing: 10) {
                    Text("Du bist bereit!")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    Text("Dein Wingman wartet.\nLass die Matches kommen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .offset(y: textOffset)
                .opacity(textOpacity)
            }
        }
        .onAppear { startAnimation() }
    }

    private func startAnimation() {
        // Logo pop in
        withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) {
            logoScale = 1; logoOpacity = 1
        }
        // Pulse ring
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulseScale = 1.18
        }
        // Text slide up
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75).delay(0.3)) {
            textOffset = 0; textOpacity = 1
        }
        // Spawn floating hearts
        let screenW = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 375
        for i in 0..<18 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.14) {
                let h = FloatingHeart(
                    startX: CGFloat.random(in: 40...(screenW - 40)),
                    size: CGFloat.random(in: 14...34),
                    color: heartColors.randomElement()!
                )
                hearts.append(h)
                let idx = hearts.count - 1
                // Fade + float up
                withAnimation(.easeOut(duration: 0.3)) {
                    hearts[idx].opacity = Double.random(in: 0.65...1.0)
                    hearts[idx].scale = CGFloat.random(in: 0.8...1.2)
                }
                withAnimation(.easeInOut(duration: Double.random(in: 1.8...2.8))) {
                    hearts[idx].offsetY = -CGFloat.random(in: 160...320)
                    hearts[idx].offsetX = CGFloat.random(in: -30...30)
                }
                withAnimation(.easeIn(duration: 0.8).delay(Double.random(in: 1.2...2.0))) {
                    hearts[idx].opacity = 0
                }
            }
        }
    }
}

private struct GenderTile: View {
    let title: String
    let icon: String
    let value: Gender
    @Binding var selection: Gender
    let brand: Color

    private var isSelected: Bool { selection == value }
    private let brandAlt = Color(.sRGB, red: 0xF5/255, green: 0x7C/255, blue: 0x5B/255, opacity: 1)

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selection = value
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(isSelected ? .white : brand)
                    .scaleEffect(isSelected ? 1.15 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .primary)
            }
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(
                Group {
                    if isSelected {
                        LinearGradient(colors: [brand, brandAlt], startPoint: .topLeading, endPoint: .bottomTrailing)
                    } else {
                        LinearGradient(colors: [Color(.systemBackground).opacity(0.95), Color(.systemBackground).opacity(0.95)], startPoint: .top, endPoint: .bottom)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? Color.clear : Color.gray.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: isSelected ? brand.opacity(0.35) : .black.opacity(0.04), radius: isSelected ? 12 : 4, y: isSelected ? 6 : 2)
            .scaleEffect(isSelected ? 1.04 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}


private struct PrimaryGradientButton: View {
    let title: String
    let brand: Color
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                Text(title).font(.headline).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right").font(.headline).foregroundStyle(.white.opacity(0.9))
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(LinearGradient(colors: [brand.opacity(0.85), brand], startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
            .opacity(isDisabled ? 0.55 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct BioAIDirectionSheet: View {
    let brand: Color
    let currentBio: String
    let displayName: String
    let city: String
    let gender: String?
    let interestedIn: [String]
    let lookingFor: String
    let interests: [String]
    let keywords: [String]
    @ObservedObject var ai: OnboardingAIViewModel
    let onSelect: (String) -> Void

    enum Tone: String, CaseIterable, Identifiable {
        case playful, witty, direct, warm, serious
        var id: String { rawValue }
        var label: String {
            switch self {
            case .playful: return "Verspielt"
            case .witty:   return "Witzig"
            case .direct:  return "Direkt"
            case .warm:    return "Herzlich"
            case .serious: return "Ernst"
            }
        }
        var subtitle: String {
            switch self {
            case .playful: return "locker & charmant"
            case .witty:   return "humor & schlagfertig"
            case .direct:  return "klar & auf den Punkt"
            case .warm:    return "offen & nahbar"
            case .serious: return "tiefgründig & fokussiert"
            }
        }
        var icon: String {
            switch self {
            case .playful: return "face.smiling"
            case .witty:   return "sparkles"
            case .direct:  return "bolt.fill"
            case .warm:    return "heart.fill"
            case .serious: return "target"
            }
        }
    }

    enum BioLen: String, CaseIterable, Identifiable {
        case short, medium
        var id: String { rawValue }
        var label: String {
            switch self {
            case .short:  return "Kurz (1–2 Zeilen)"
            case .medium: return "Mittel (3–5 Zeilen)"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var tone: Tone = .playful
    @State private var bioLen: BioLen = .short
    @State private var isGenerating: Bool = false
    @State private var suggestions: [String] = []

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bio-Vorschläge")
                            .font(.title2.weight(.bold))
                        Text("Wähle Stil und Länge – der Wingman schreibt für dich.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Tone grid
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Stil")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(Tone.allCases) { t in
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    withAnimation(.easeInOut(duration: 0.15)) { tone = t }
                                } label: {
                                    HStack(spacing: 10) {
                                        ZStack {
                                            Circle()
                                                .fill(tone == t ? Color.white.opacity(0.22) : brand.opacity(0.10))
                                                .frame(width: 34, height: 34)
                                            Image(systemName: t.icon)
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(tone == t ? .white : brand)
                                        }
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(t.label)
                                                .font(.subheadline.weight(.semibold))
                                            Text(t.subtitle)
                                                .font(.caption2)
                                                .opacity(0.8)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .foregroundStyle(tone == t ? .white : .primary)
                                    .background(
                                        tone == t
                                            ? AnyShapeStyle(LinearGradient(
                                                colors: [brand, brand.opacity(0.78)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                                            : AnyShapeStyle(Color(.systemGray6))
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14)
                                        .stroke(tone == t ? Color.clear : Color.gray.opacity(0.15), lineWidth: 1))
                                    .shadow(color: tone == t ? brand.opacity(0.28) : .clear, radius: 8, y: 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Length selector
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Länge")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $bioLen) {
                            ForEach(BioLen.allCases) { l in
                                Text(l.label).tag(l)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    PrimaryGradientButton(
                        title: isGenerating ? "Wird geschrieben…" : "Vorschläge generieren",
                        brand: brand,
                        isDisabled: isGenerating
                    ) {
                        Task { await generateWithAI() }
                    }

                    // Suggestions
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Wähle einen Vorschlag")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(Array(suggestions.enumerated()), id: \.offset) { idx, option in
                                Button {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    onSelect(option)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(option)
                                            .font(.subheadline)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .multilineTextAlignment(.leading)
                                            .foregroundStyle(.primary)
                                        HStack {
                                            Spacer()
                                            HStack(spacing: 4) {
                                                Image(systemName: "checkmark")
                                                    .font(.caption.weight(.bold))
                                                Text("Übernehmen")
                                                    .font(.caption.weight(.semibold))
                                            }
                                            .foregroundStyle(brand)
                                        }
                                    }
                                    .padding(16)
                                    .background(Color(.systemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16)
                                        .stroke(Color.gray.opacity(0.15), lineWidth: 1))
                                    .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
                                }
                                .buttonStyle(.plain)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                        .animation(.easeOut(duration: 0.22), value: suggestions.count)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Schließen") { dismiss() }.tint(brand)
                }
            }
        }
        .tint(brand)
    }

    private func generateWithAI() async {
        isGenerating = true
        defer { isGenerating = false }

        let bioTone = BioInput.Tone(rawValue: tone.rawValue) ?? .playful
        let bioLength = BioInput.BioLength(rawValue: bioLen.rawValue) ?? .short

        let input = BioInput(
            displayName: displayName.trimmed.isEmpty ? nil : displayName.trimmed,
            gender: gender,
            interestedIn: interestedIn.isEmpty ? nil : interestedIn,
            city: city.trimmed.isEmpty ? nil : city.trimmed,
            lookingFor: lookingFor.isEmpty ? nil : lookingFor,
            interests: interests,
            keywords: keywords,
            tone: bioTone,
            length: bioLength,
            adjustment: nil
        )

        await ai.generateBio(input: input)
        suggestions = ai.bioOptions
    }
}

// MARK: - Camera Picker

private struct CameraPickerView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onCapture: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
            picker.cameraDevice = .front
        } else {
            picker.sourceType = .photoLibrary
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerView
        init(_ parent: CameraPickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.onCapture(info[.originalImage] as? UIImage)
            parent.isPresented = false
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCapture(nil)
            parent.isPresented = false
        }
    }
}
