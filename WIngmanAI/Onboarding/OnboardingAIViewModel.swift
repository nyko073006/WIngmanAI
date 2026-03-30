import Foundation
import Combine

@MainActor
final class OnboardingAIViewModel: ObservableObject {
    // BIO
    @Published var bioLoading = false
    @Published var bioError: String? = nil
    @Published var bioOptions: [String] = []
    @Published var selectedBio: String = ""

    // PROMPTS
    @Published var promptsLoading = false
    @Published var promptsError: String? = nil
    /// answers[i] = options for prompt i
    @Published var promptAnswerOptions: [[String]] = [[], [], []]
    @Published var selectedPromptAnswers: [String] = ["", "", ""]

    // HOOKS / VIBES
    @Published var hooksLoading = false
    @Published var hooksError: String? = nil
    @Published var hookOptions: [String] = []
    @Published var selectedHooks: Set<String> = []
    @Published var vibeOptions: [String] = []
    @Published var selectedVibes: Set<String> = []

    // MARK: - Public actions

    func generateBio(input: BioInput) async {
        bioLoading = true
        bioError = nil
        defer { bioLoading = false }

        do {
            let res = try await AIService.shared.generateBio(input: input)
            bioOptions = sanitize(res.bios)
            selectedBio = bioOptions.first ?? ""
        } catch {
            // fallback
            bioError = friendly(error)
            bioOptions = fallbackBios(input: input)
            selectedBio = bioOptions.first ?? ""
        }
    }

    func generatePrompts(input: PromptsInput) async {
        promptsLoading = true
        promptsError = nil
        defer { promptsLoading = false }

        do {
            let res = try await AIService.shared.generatePromptAnswers(input: input)
            let safe = res.answers.prefix(3).map { sanitize($0) }
            promptAnswerOptions = Array(safe) + Array(repeating: [], count: max(0, 3 - safe.count))
            // default select first for each
            for i in 0..<3 {
                selectedPromptAnswers[i] = promptAnswerOptions[i].first ?? ""
            }
        } catch {
            promptsError = friendly(error)
            let fb = fallbackPromptAnswers(prompts: input.prompts, context: input)
            promptAnswerOptions = fb
            for i in 0..<3 { selectedPromptAnswers[i] = fb[i].first ?? "" }
        }
    }

    func generateHooks(input: HooksInput) async {
        hooksLoading = true
        hooksError = nil
        defer { hooksLoading = false }

        do {
            let res = try await AIService.shared.generateHooks(input: input)
            hookOptions = sanitize(res.hooks)
            vibeOptions = sanitize(res.firstDateVibes)
            selectedHooks = Set(hookOptions.prefix(2))
            selectedVibes = []
        } catch {
            hooksError = friendly(error)
            hookOptions = fallbackHooks(context: input)
            vibeOptions = fallbackVibes()
            selectedHooks = Set(hookOptions.prefix(2))
            selectedVibes = []
        }
    }

    // MARK: - Helpers

    private func sanitize(_ list: [String]) -> [String] {
        Array(
            list
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(12)
        )
    }

    private func friendly(_ error: Error) -> String {
        let msg = (error as NSError).localizedDescription
        // deine typischen Fälle
        if msg.contains("429") { return "AI gerade über Limit – ich nutze Fallback." }
        if msg.contains("401") { return "AI Auth-Problem – ich nutze Fallback." }
        return "AI gerade nicht verfügbar – ich nutze Fallback."
    }

    // MARK: - Fallbacks (keine Cringe-Texte)

    private func fallbackBios(input: BioInput) -> [String] {
        let i1 = input.interests.first ?? "gute Vibes"
        let i2 = input.interests.dropFirst().first ?? "spontane Pläne"
        switch input.tone {
        case .direct:
            return [
                "Klar im Kopf, entspannt im Umgang. Kein Drama.",
                "Meistens bei \(i1). Manchmal auch nicht.",
                "Sag einfach hi – ich beiß nicht."
            ]
        case .witty:
            return [
                "Hauptberuflich \(i1)-Enthusiast.",
                "Ich hab Meinungen zu \(i2). Viele.",
                "Dein Opener entscheidet alles. Keine Panik."
            ]
        case .warm:
            return [
                "Mag ehrliche Menschen und \(i1).",
                "Bei mir gibt’s immer \(i2) und keinen Smalltalk.",
                "Schreib mir, was dich heute beschäftigt."
            ]
        case .serious:
            return [
                "Ich weiß was ich will. \(i1) gehört dazu.",
                "Langfristig denken, im Moment leben.",
                "Wenn du’s ernst meinst: schreib."
            ]
        case .playful:
            return [
                "\(i1) tagsüber, \(i2) nachts.",
                "Locker drauf, aber nicht oberflächlich.",
                "Mach mir ein Angebot."
            ]
        }
    }

    private func fallbackPromptAnswers(prompts: [String], context: PromptsInput) -> [[String]] {
        // 3 Prompts → je 3 Optionen
        return prompts.enumerated().map { idx, p in
            let base: [String] = [
                "Guter Kaffee, gute Musik, dann was Spontanes – ohne Stress.",
                "Gym erledigt, Kopf frei, danach irgendwas, worüber man lachen kann.",
                "Ein Plan ist gut. Ein besserer Plan ist: einfach machen."
            ]
            // kleine Variation pro Prompt
            if idx == 1 {
                return [
                    "Mein Green Flag? Ehrlich sein, auch wenn’s unbequem ist.",
                    "Wenn du Klartext magst und nicht ghostest, sind wir schon weit.",
                    "Respekt + Humor. Der Rest ist Bonus."
                ]
            }
            if idx == 2 {
                return [
                    "Sag mir deinen Lieblingssong und ich rate deinen Vibe.",
                    "Ich wähle den Spot, du wählst die Musik – fair?",
                    "Ein Date ohne Smalltalk-Challenge: bist du dabei?"
                ]
            }
            return base
        }
    }

    private func fallbackHooks(context: HooksInput) -> [String] {
        let ints = context.interests.prefix(3).joined(separator: " / ")
        return [
            "Ich kann dir in 30 Sekunden sagen, ob ein Café was taugt.",
            "Meine Woche ist besser, wenn \(ints) drin vorkommt.",
            "Ich bin Team Klartext – was ist deine größte Green Flag?",
            "Ich hab eine Theorie: Musikgeschmack sagt mehr als Sternzeichen.",
            "Wenn du spontan bist: 1 Sache, die du sofort machen würdest?"
        ]
    }

    private func fallbackVibes() -> [String] {
        ["entspannt", "lustig", "spontan", "ehrlich", "deep talk", "walk & talk", "coffee date", "low pressure"]
    }
}
