
import SwiftUI
import Supabase
import Foundation

// MARK: - Step 3 helpers (Last Seen)

@MainActor
extension MatchesViewModel {
    /// Persist last seen time for a match and clear unread badge optimistically.
    func markSeen(matchId: UUID, at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: "match_last_seen_\(matchId.uuidString)")

        // Optimistic UI update: clear unread badge immediately.
        if let idx = items.firstIndex(where: { $0.id == matchId }) {
            let cur = items[idx]
            items[idx] = MatchItem(
                id: cur.id,
                otherUserId: cur.otherUserId,
                name: cur.name,
                photoUrl: cur.photoUrl,
                lastMessageAt: cur.lastMessageAt,
                lastMessageText: cur.lastMessageText,
                subtitle: cur.subtitle,
                unreadCount: 0
            )
        }
    }
}

// MARK: - Matches View

struct MatchesView: View {
    let myId: UUID
    var activeChatMatchId: UUID? = nil

    /// Parent provides navigation (e.g. present ChatView).
    var onOpenChat: (MatchesViewModel.MatchItem) -> Void

    @ObservedObject var vm: MatchesViewModel
    @State private var profileSheetUser: IdentifiableUUID? = nil
    @State private var blockAlertMatch: MatchesViewModel.MatchItem? = nil
    @State private var reportAlertMatch: MatchesViewModel.MatchItem? = nil
    @State private var unmatchAlertMatch: MatchesViewModel.MatchItem? = nil
    
    @AppStorage("matches_view_style") private var viewStyle: String = "list"

    // MARK: - Step 3.1 Realtime (unread badges)

    @State private var channels: [UUID: RealtimeChannelV2] = [:]
    @State private var streamTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - New match realtime
    @State private var newMatchChannelLow: RealtimeChannelV2? = nil
    @State private var newMatchChannelHigh: RealtimeChannelV2? = nil
    @State private var newMatchTaskLow: Task<Void, Never>? = nil
    @State private var newMatchTaskHigh: Task<Void, Never>? = nil

    private var client: SupabaseClient { SupabaseClientProvider.shared.client }

    private struct RTMessageRow: Decodable {
        let id: UUID
        let match_id: UUID
        let sender_id: UUID
        let text: String
        let created_at: Date
    }

    private static let rtDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)

            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]

            if let dt = f1.date(from: s) ?? f2.date(from: s) { return dt }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO8601 date: \(s)")
        }
        return d
    }()

    init(myId: UUID, activeChatMatchId: UUID? = nil, vm: MatchesViewModel, onOpenChat: @escaping (MatchesViewModel.MatchItem) -> Void) {
        self.myId = myId
        self.activeChatMatchId = activeChatMatchId
        self._vm = ObservedObject(wrappedValue: vm)
        self.onOpenChat = onOpenChat
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Image("colored-logo-ohne-schrift")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 32)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Picker("Ansicht", selection: $viewStyle) {
                            Image(systemName: "list.bullet").tag("list")
                            Image(systemName: "square.grid.2x2").tag("grid")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 90)
                    }
                }
                .task {
                    await vm.load(myId: myId)
                    syncRealtimeSubscriptions()
                    startNewMatchRealtime()
                }
                .refreshable {
                    await vm.load(myId: myId)
                    syncRealtimeSubscriptions()
                }
                .onChange(of: vm.items.map(\.id)) { _, _ in
                    syncRealtimeSubscriptions()
                }
                .onDisappear {
                    stopAllRealtime()
                    stopNewMatchRealtime()
                }
                .sheet(item: $profileSheetUser) { wrapper in
                    OtherUserProfileSheet(userId: wrapper.id)
                }
                .alert("Blockieren?", isPresented: Binding(
                    get: { blockAlertMatch != nil },
                    set: { if !$0 { blockAlertMatch = nil } }
                )) {
                    Button("Blockieren", role: .destructive) {
                        if let item = blockAlertMatch {
                            let matchId = item.id
                            vm.items.removeAll { $0.id == matchId }
                            Task {
                                do {
                                    try await SwipeService.shared.block(blockerId: myId, blockedId: item.otherUserId)
                                    try await SupabaseClientProvider.shared.client.from("matches").delete().eq("id", value: matchId.uuidString).execute()
                                } catch {
                                    vm.items.insert(item, at: 0)
                                }
                            }
                        }
                        blockAlertMatch = nil
                    }
                    Button("Abbrechen", role: .cancel) { blockAlertMatch = nil }
                } message: {
                    Text("Dieser Nutzer wird blockiert und das Match gelöscht.")
                }
                .confirmationDialog(
                    "Melden: \(reportAlertMatch?.name ?? "")",
                    isPresented: Binding(get: { reportAlertMatch != nil }, set: { if !$0 { reportAlertMatch = nil } }),
                    titleVisibility: .visible
                ) {
                    ForEach(["Spam", "Belästigung", "Fake-Profil", "Unangemessene Fotos", "Sonstiges"], id: \.self) { reason in
                        Button(reason) {
                            if let item = reportAlertMatch {
                                Task { try? await SwipeService.shared.report(reporterId: myId, reportedId: item.otherUserId, reason: reason) }
                            }
                            reportAlertMatch = nil
                        }
                    }
                    Button("Abbrechen", role: .cancel) { reportAlertMatch = nil }
                }
                .alert("Entmatchen?", isPresented: Binding(
                    get: { unmatchAlertMatch != nil },
                    set: { if !$0 { unmatchAlertMatch = nil } }
                )) {
                    Button("Entmatchen", role: .destructive) {
                        if let item = unmatchAlertMatch {
                            let matchId = item.id
                            vm.items.removeAll { $0.id == matchId }
                            Task {
                                do {
                                    try await SupabaseClientProvider.shared.client.from("matches").delete().eq("id", value: matchId.uuidString).execute()
                                } catch {
                                    vm.items.insert(item, at: 0)
                                }
                            }
                        }
                        unmatchAlertMatch = nil
                    }
                    Button("Abbrechen", role: .cancel) { unmatchAlertMatch = nil }
                } message: {
                    Text("Das Match wird gelöscht.")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.items.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Lade Matches …")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = vm.errorText, vm.items.isEmpty {
            VStack(spacing: 10) {
                Text(err)
                    .multilineTextAlignment(.center)
                Button("Erneut laden") {
                    Task {
                        await vm.load(myId: myId)
                        syncRealtimeSubscriptions()
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.items.isEmpty {
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(matchBrand.opacity(0.08))
                        .frame(width: 110, height: 110)
                    Image(systemName: "heart.circle.fill")
                        .font(.system(size: 58))
                        .foregroundStyle(
                            LinearGradient(colors: [matchBrand, matchBrandAlt],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                }

                VStack(spacing: 8) {
                    Text("Noch keine Matches")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Text("Swipe weiter – dein Match wartet bestimmt schon.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                if viewStyle == "list" {
                    let newMatches = vm.items.filter { $0.lastMessageText == nil }
                    let activeMatches = vm.items.filter { $0.lastMessageText != nil }
                    
                    if !newMatches.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Neue Matches")
                                .font(.headline)
                                .padding(.horizontal, 16)
                                .padding(.top, 4) // Smaller top padding
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(newMatches, id: \.id) { item in
                                        NewMatchCardTile(item: item, brand: matchBrand, brandAlt: matchBrandAlt) {
                                            vm.markSeen(matchId: item.id)
                                            onOpenChat(item)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        .padding(.bottom, 8)
                        
                        Divider()
                            .padding(.leading, 16)
                    }
                    
                    if !activeMatches.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Nachrichten")
                                .font(.headline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            
                            LazyVStack(spacing: 0) {
                                ForEach(Array(activeMatches.enumerated()), id: \.element.id) { index, item in
                                    Button {
                                        vm.markSeen(matchId: item.id)
                                        onOpenChat(item)
                                    } label: {
                                        MatchRow(item: item) {
                                            profileSheetUser = IdentifiableUUID(id: item.otherUserId)
                                        }
                                        .padding(.horizontal, 16)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button {
                                            profileSheetUser = IdentifiableUUID(id: item.otherUserId)
                                        } label: {
                                            Label("Profil anzeigen", systemImage: "person.crop.circle")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            unmatchAlertMatch = item
                                        } label: {
                                            Label("Entmatchen", systemImage: "heart.slash")
                                        }
                                        Divider()
                                        Button {
                                            blockAlertMatch = item
                                        } label: {
                                            Label("Blockieren", systemImage: "hand.raised")
                                        }
                                        Button(role: .destructive) {
                                            reportAlertMatch = item
                                        } label: {
                                            Label("Melden", systemImage: "flag")
                                        }
                                    }

                                    if index < activeMatches.count - 1 {
                                        Divider()
                                            .padding(.leading, 78)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    if vm.items.isEmpty {
                        VStack(spacing: 20) {
                            ZStack {
                                Circle()
                                    .fill(matchBrand.opacity(0.08))
                                    .frame(width: 110, height: 110)
                                Image(systemName: "heart.circle.fill")
                                    .font(.system(size: 58))
                                    .foregroundStyle(
                                        LinearGradient(colors: [matchBrand, matchBrandAlt],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                                    )
                            }

                            VStack(spacing: 8) {
                                Text("Noch keine Matches")
                                    .font(.system(.title3, design: .rounded).weight(.bold))
                                Text("Swipe weiter – dein Match wartet bestimmt schon.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(2)
                            }
                        }
                        .padding(32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            ForEach(vm.items, id: \.id) { item in
                                MatchGridTile(item: item, brand: matchBrand, brandAlt: matchBrandAlt) {
                                    vm.markSeen(matchId: item.id)
                                    onOpenChat(item)
                                } onProfileTap: {
                                    profileSheetUser = IdentifiableUUID(id: item.otherUserId)
                                }
                                .contextMenu {
                                    Button {
                                        profileSheetUser = IdentifiableUUID(id: item.otherUserId)
                                    } label: {
                                        Label("Profil anzeigen", systemImage: "person.crop.circle")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        unmatchAlertMatch = item
                                    } label: {
                                        Label("Entmatchen", systemImage: "heart.slash")
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
    }

    // MARK: - Realtime wiring

    private func syncRealtimeSubscriptions() {
        let currentIds = Set(vm.items.map { $0.id })

        // Stop subscriptions for removed matches
        for (matchId, task) in streamTasks where !currentIds.contains(matchId) {
            task.cancel()
            streamTasks[matchId] = nil
            if let ch = channels[matchId] {
                Task { await client.realtimeV2.removeChannel(ch) }
            }
            channels[matchId] = nil
        }

        // Start subscriptions for new matches
        for matchId in currentIds where channels[matchId] == nil {
            startRealtime(matchId: matchId)
        }
    }

    private func startRealtime(matchId: UUID) {
        let uniqueName = "matches-\(matchId.uuidString)-\(UUID().uuidString)"
        let ch = client.realtimeV2.channel(uniqueName)
        channels[matchId] = ch

        let stream = ch.postgresChange(
            Realtime.InsertAction.self,
            schema: "public",
            table: "messages",
            filter: .eq("match_id", value: matchId.uuidString)
        )

        streamTasks[matchId] = Task {
            do {
                try await ch.subscribeWithError()
            } catch {
                return
            }

            do {
                for await insert in stream {
                    let row = try insert.decodeRecord(as: RTMessageRow.self, decoder: Self.rtDecoder)
                    await MainActor.run {
                        applyIncoming(row: row)
                    }
                }
            } catch {
                if Task.isCancelled { return }
            }

            // Stream ended — reconnect after 2s
            guard !Task.isCancelled else { return }
            await client.realtimeV2.removeChannel(ch)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            channels[matchId] = nil
            streamTasks[matchId] = nil
            startRealtime(matchId: matchId)
        }
    }

    private func stopAllRealtime() {
        for (_, task) in streamTasks { task.cancel() }
        streamTasks.removeAll()

        for (_, ch) in channels {
            Task { await client.realtimeV2.removeChannel(ch) }
        }
        channels.removeAll()
    }

    // MARK: - New match realtime (watches matches table for INSERTs)

    private func startNewMatchRealtime() {
        guard newMatchChannelLow == nil else { return }

        let uid = myId.uuidString.lowercased()

        let chLow = client.realtimeV2.channel("new-match-low-\(uid)-\(UUID().uuidString)")
        let chHigh = client.realtimeV2.channel("new-match-high-\(uid)-\(UUID().uuidString)")
        newMatchChannelLow = chLow
        newMatchChannelHigh = chHigh

        let streamLow = chLow.postgresChange(
            Realtime.InsertAction.self,
            schema: "public",
            table: "matches",
            filter: .eq("user_low", value: uid)
        )
        let streamHigh = chHigh.postgresChange(
            Realtime.InsertAction.self,
            schema: "public",
            table: "matches",
            filter: .eq("user_high", value: uid)
        )

        newMatchTaskLow = Task {
            do { try await chLow.subscribeWithError() } catch { return }
            for await _ in streamLow {
                await vm.load(myId: myId)
                await MainActor.run { syncRealtimeSubscriptions() }
            }
        }

        newMatchTaskHigh = Task {
            do { try await chHigh.subscribeWithError() } catch { return }
            for await _ in streamHigh {
                await vm.load(myId: myId)
                await MainActor.run { syncRealtimeSubscriptions() }
            }
        }
    }

    private func stopNewMatchRealtime() {
        newMatchTaskLow?.cancel(); newMatchTaskLow = nil
        newMatchTaskHigh?.cancel(); newMatchTaskHigh = nil
        if let ch = newMatchChannelLow { Task { await client.realtimeV2.removeChannel(ch) } }
        if let ch = newMatchChannelHigh { Task { await client.realtimeV2.removeChannel(ch) } }
        newMatchChannelLow = nil
        newMatchChannelHigh = nil
    }

    private func applyIncoming(row: RTMessageRow) {
        guard let idx = vm.items.firstIndex(where: { $0.id == row.match_id }) else { return }
        let cur = vm.items[idx]

        let isImg = row.text.hasPrefix("[IMG]")
        let displayText = isImg ? "📷 Foto" : row.text
        let newSubtitle: String? = (row.sender_id == myId) ? "Du: \(displayText)" : displayText

        var newUnread = cur.unreadCount
        if row.sender_id != myId {
            if activeChatMatchId != row.match_id {
                newUnread += 1
                LocalNotificationHelper.shared.scheduleNewMessage(
                    from: cur.name,
                    text: isImg ? "📷 hat ein Foto gesendet" : row.text,
                    matchId: row.match_id
                )
            } else {
                UserDefaults.standard.set(Date(), forKey: "match_last_seen_\(row.match_id.uuidString)")
                newUnread = 0
            }
        }

        vm.items[idx] = MatchesViewModel.MatchItem(
            id: cur.id,
            otherUserId: cur.otherUserId,
            name: cur.name,
            photoUrl: cur.photoUrl,
            lastMessageAt: row.created_at,
            lastMessageText: row.text,
            subtitle: newSubtitle,
            unreadCount: newUnread
        )

        vm.items.sort { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
    }
}

private let matchBrand    = Color(.sRGB, red: 0xE8/255, green: 0x60/255, blue: 0x7A/255, opacity: 1)
private let matchBrandAlt = Color(.sRGB, red: 0xF5/255, green: 0x7C/255, blue: 0x5B/255, opacity: 1)

private struct MatchRow: View {
    let item: MatchesViewModel.MatchItem
    var onProfileTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            avatar
                .onTapGesture {
                    onProfileTap?()
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name)
                        .font(.system(.headline, design: .rounded))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let d = item.lastMessageAt {
                        Text(d, style: .time)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if item.lastMessageText == nil {
                    HStack(spacing: 6) {
                        Text("Sag Hallo! 👋")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(matchBrand)
                        Spacer()
                        Text("Neu")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(matchBrand, in: Capsule())
                    }
                } else {
                    Text(item.subtitle ?? item.lastMessageText ?? "")
                        .font(.subheadline)
                        .foregroundStyle(item.unreadCount > 0 ? .primary : .secondary)
                        .lineLimit(1)
                        .fontWeight(item.unreadCount > 0 ? .medium : .regular)
                }
            }

            if item.unreadCount > 0 {
                unreadBadge(count: item.unreadCount)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var avatar: some View {
        ZStack {
            // Gradient ring when unread or no messages yet (nudge to write)
            if item.unreadCount > 0 || item.lastMessageText == nil {
                Circle()
                    .fill(
                        LinearGradient(colors: [matchBrand, matchBrandAlt],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 62, height: 62)
                    .opacity(item.unreadCount > 0 ? 1.0 : 0.45)
            }

            Group {
                if let s = item.photoUrl, let url = URL(string: s) {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Image(systemName: "person.circle.fill")
                                .resizable().scaledToFit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable().scaledToFit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: (item.unreadCount > 0 || item.lastMessageText == nil) ? 56 : 58,
                   height: (item.unreadCount > 0 || item.lastMessageText == nil) ? 56 : 58)
            .clipShape(Circle())
            .shadow(color: (item.unreadCount > 0 || item.lastMessageText == nil) ? matchBrand.opacity(0.25) : .black.opacity(0.08),
                    radius: (item.unreadCount > 0 || item.lastMessageText == nil) ? 8 : 4, y: 3)
        }
    }

    private func unreadBadge(count: Int) -> some View {
        let text = count > 99 ? "99+" : String(count)
        return Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                LinearGradient(colors: [matchBrand, matchBrandAlt], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Capsule()
            )
            .shadow(color: matchBrand.opacity(0.4), radius: 6, y: 3)
    }
}

private struct MatchGridTile: View {
    let item: MatchesViewModel.MatchItem
    let brand: Color
    let brandAlt: Color
    let onTap: () -> Void
    let onProfileTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let s = item.photoUrl, let url = URL(string: s) {
                            CachedAsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    Image(systemName: "person.circle.fill")
                                        .resizable().scaledToFit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Image(systemName: "person.circle.fill")
                                .resizable().scaledToFit()
                                .foregroundStyle(.secondary)
                                .padding(20)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    
                    if item.unreadCount > 0 || item.lastMessageText == nil {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(colors: [brand, brandAlt], startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 3
                            )
                    }
                    
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.5),
                            .init(color: .black.opacity(0.8), location: 1.0)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            
                            if item.lastMessageText == nil {
                                Text("Neu")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(brand, in: Capsule())
                            } else if item.unreadCount > 0 {
                                Text("\(item.unreadCount) neu")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(brandAlt)
                            }
                        }
                        
                        Spacer()
                        
                        Button(action: onProfileTap) {
                            Image(systemName: "info.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.9))
                                .accessibilityLabel("Profil anzeigen")
                        }
                    }
                    .padding(12)
                }
            }
            .aspectRatio(3/4, contentMode: .fill)
            .shadow(color: .black.opacity(0.1), radius: 6, y: 4)
        }
        .buttonStyle(.plain)
    }
}

private struct NewMatchCardTile: View {
    let item: MatchesViewModel.MatchItem
    let brand: Color
    let brandAlt: Color
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottom) {
                Group {
                    if let s = item.photoUrl, let url = URL(string: s) {
                        CachedAsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                Image(systemName: "person.circle.fill")
                                    .resizable().scaledToFit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Image(systemName: "person.circle.fill")
                            .resizable().scaledToFit()
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
                .frame(width: 85, height: 115)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                // Outline border for new matches
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(colors: [brand, brandAlt], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 2
                    )

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.4),
                        .init(color: .black.opacity(0.85), location: 1.0)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(width: 85, height: 115)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                // Name
                Text(item.name.components(separatedBy: " ").first ?? item.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: brand.opacity(0.15), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}
