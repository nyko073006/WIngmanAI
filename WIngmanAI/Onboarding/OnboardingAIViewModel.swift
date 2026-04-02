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
            selectedHooks = []
            selectedVibes = []
        } catch {
            hooksError = friendly(error)
            hookOptions = fallbackHooks(context: input)
            vibeOptions = fallbackVibes(context: input)
            selectedHooks = []
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
        print("REAL AI ERROR RAW:", msg) // ALWAYS PRINT IT
        
        if msg.contains("HTTP 429") { return "AI gerade über Limit – ich nutze Fallback." }
        if msg.contains("HTTP 401") { return "AI Auth-Problem – ich nutze Fallback." }

        return "AI Error: \(msg)"
    }

    // MARK: - Fallbacks (keine Cringe-Texte)

    private func fallbackBios(input: BioInput) -> [String] {
        let i1 = input.interests.first ?? "gute Vibes"
        let i2 = input.interests.dropFirst().first ?? "spontane Pläne"
        let isLong   = input.length == .long
        let isMedium = input.length == .medium

        switch input.tone {
        case .direct:
            if isLong {
                return [
                    "Klar im Kopf, entspannt im Umgang. Kein Drama, keine Spielchen. Ich sag, was ich denke – freundlich, aber direkt. Was du hier liest, ist das, was du auch im echten Leben bekommst. Das schätzen manche, andere nicht. Beides ist okay.",
                    "Meistens bei \(i1), manchmal bei \(i2) – je nachdem, was der Tag bringt. Ich mag’s, wenn Dinge klar sind und Pläne eingehalten werden. Spontan sein kann ich auch, aber verlässlich sein kann ich besser. Wenn du ähnlich drauf bist: hi.",
                    "Sag einfach hi, ich beiß nicht. Ich bin kein Fan von wochenlangem Schreiben ohne Ziel. Wenn’s passt, merken wir das schnell – wenn nicht, auch. Ich finde direkte Kommunikation einfacher als höfliche Umwege."
                ]
            } else if isMedium {
                return [
                    "Klar im Kopf, entspannt im Umgang. Kein Drama, keine Spielchen – was du siehst, ist was du kriegst. Ich mag’s, wenn das auf Gegenseitigkeit beruht.",
                    "\(i1) ist ein fester Teil meines Alltags. Dazu kommt \(i2), wenn die Zeit passt. Ich weiß, was mir wichtig ist – das macht Gespräche einfacher.",
                    "Sag einfach hi, ich beiß nicht. Wenn’s passt, merken wir das schnell – dann machen wir was draus."
                ]
            }
            return [
                "Klar im Kopf, entspannt im Umgang. Kein Drama.",
                "Meistens bei \(i1). Manchmal auch nicht.",
                "Sag einfach hi – ich beiß nicht."
            ]
        case .witty:
            if isLong {
                return [
                    "Hauptberuflich \(i1)-Enthusiast, nebenberuflich jemand, der zu viele Meinungen zu \(i2) hat. Ich bin der Typ, der beim ersten Date schon Witze macht, die nicht alle verstehen – aber die, die sie verstehen, werden es schätzen. Humor ist mein Filter. Wirkt.",
                    "Dein Opener entscheidet alles. Keine Panik – aber auch kein ‘Hey’. Du kannst das besser, ich glaube an dich. Ich verspreche im Gegenzug: kein generisches Smalltalk-Programm. Dafür echte Unterhaltung, die manchmal absurde Züge annimmt.",
                    "Ich finde Humor wichtiger als einen perfekten Lebenslauf. Humor ist auch schwerer zu faken. Ich mag Menschen, die über sich selbst lachen können – das sagt mehr aus als jede Liste mit Hobbys. Wenn du das genauso siehst: schreib mir was, das mich zum Lachen bringt."
                ]
            } else if isMedium {
                return [
                    "Hauptberuflich \(i1)-Enthusiast – nebenberuflich hab ich zu allem eine Meinung, auch zu \(i2). Viele.",
                    "Dein Opener entscheidet alles. Keine Panik, aber auch kein ‘Hey’. Du kannst das besser.",
                    "Humor ist schwerer zu faken als ein perfekter Lebenslauf. Das ist mein einziges Auswahlkriterium."
                ]
            }
            return [
                "Hauptberuflich \(i1)-Enthusiast.",
                "Ich hab Meinungen zu \(i2). Viele.",
                "Dein Opener entscheidet alles. Keine Panik."
            ]
        case .warm:
            if isLong {
                return [
                    "Mag ehrliche Menschen, \(i1) und Gespräche, die irgendwo hinführen. Nicht die Art, wo man höflich nickt – sondern die, die dich danach noch beschäftigen. Ich find’s schöner, wenn man direkt beim Echten landet. Kein Smalltalk nötig. Schreib mir einfach, was dich heute wirklich bewegt.",
                    "Bei mir dreht sich vieles um \(i1) und \(i2) – aber vor allem um die Menschen dahinter. Ich mag es, wenn jemand erzählt, was ihn wirklich antreibt. Oberflächliche Gespräche kosten mich Energie, echte geben sie mir zurück. Wenn du das genauso siehst, sind wir schon auf einer Wellenlänge.",
                    "Ich bin jemand, der gerne zuhört und genauso gerne erzählt. \(i1) ist ein großer Teil meines Alltags – nicht weil es cool klingt, sondern weil es mich wirklich interessiert. Ich suche keine Perfektion, sondern jemanden, mit dem man auch einfach mal nichts tun kann."
                ]
            } else if isMedium {
                return [
                    "Mag ehrliche Menschen, \(i1) und Gespräche, die irgendwo hinführen. Ich find’s schöner, wenn man direkt beim Echten landet.",
                    "Bei mir gibt’s immer \(i2) und keinen Smalltalk. Oberflächliche Gespräche kosten mich Energie – echte geben sie mir zurück.",
                    "Schreib mir, was dich heute beschäftigt. Ich hör zu, frag zurück und meld mich nicht nach drei Tagen mit ‘sorry war busy’."
                ]
            }
            return [
                "Mag ehrliche Menschen und \(i1).",
                "Bei mir gibt’s immer \(i2) und keinen Smalltalk.",
                "Schreib mir, was dich heute beschäftigt."
            ]
        case .serious:
            if isLong {
                return [
                    "Ich weiß was ich will – \(i1) gehört dazu, genauso wie Verlässlichkeit und klare Kommunikation. Ich investiere viel in Dinge, die mir wichtig sind, und erwarte das auch von anderen. Keine Spielchen, kein Ghosting, kein ‘mal schauen’. Ich schaue nicht mal – ich entscheide.",
                    "Langfristig denken und im Moment leben ist kein Widerspruch – beides geht, wenn man weiß, was man will. Ich mag Gespräche über Ziele, Werte und die Dinge, die einen wirklich beschäftigen. \(i2) spielt dabei eine Rolle, aber der Mensch dahinter zählt mehr.",
                    "Wenn du weißt, was du suchst und bereit bist, das auch zu sagen: schreib mir. Ich bin nicht hier für Zeitvertreib. Ich bin hier, weil ich glaube, dass man den richtigen Menschen auch aktiv suchen muss."
                ]
            } else if isMedium {
                return [
                    "Ich weiß was ich will – \(i1) gehört dazu, genauso wie Verlässlichkeit und ehrliche Kommunikation. Keine Spielchen.",
                    "Langfristig denken, im Moment leben. Das klingt widersprüchlich, ist aber eigentlich ganz einfach, wenn man weiß, was man will.",
                    "Wenn du’s ernst meinst und weißt was du suchst: schreib mir. Der Rest ergibt sich."
                ]
            }
            return [
                "Ich weiß was ich will. \(i1) gehört dazu.",
                "Langfristig denken, im Moment leben.",
                "Wenn du’s ernst meinst: schreib."
            ]
        case .playful:
            if isLong {
                return [
                    "\(i1) tagsüber, \(i2) nachts – dazwischen alles, worüber man lachen kann. Ich bin jemand, der den Alltag nicht zu ernst nimmt, aber Gespräche schon. Klingt widersprüchlich, macht aber Sinn, wenn man mich kennt. Gib mir die Chance.",
                    "Locker drauf, aber nicht oberflächlich. Ich mag Menschen, die Spaß haben können und trotzdem wissen, was sie wollen. Bei mir gibt’s keine peinliche Stille – dafür manchmal absurde Ideen, spontane Pläne und zu viele Tabs offen. Alles gut.",
                    "Mach mir ein Angebot. Ich bin offen für gute Ideen, schlechte Witze und alles dazwischen. Ernst gemeinte Nachrichten werden ernst beantwortet. Lustige auch. Das Einzige, was ich nicht beantworte: ‘Hey, wie geht’s?’ ohne Kontext."
                ]
            } else if isMedium {
                return [
                    "\(i1) tagsüber, \(i2) nachts – dazwischen alles, worüber man lachen kann. Locker drauf, aber nicht oberflächlich.",
                    "Ich mag Menschen, die Spaß haben können und trotzdem wissen, was sie wollen. Bei mir gibt’s keine peinliche Stille.",
                    "Mach mir ein Angebot. Ich bin offen für gute Ideen – und schlechte Witze beantworte ich auch."
                ]
            }
            return [
                "\(i1) tagsüber, \(i2) nachts.",
                "Locker drauf, aber nicht oberflächlich.",
                "Mach mir ein Angebot."
            ]
        case .authentic:
            if isLong {
                return [
                    "Kein Filter, keine Rolle – einfach ich. Was du hier liest, ist das, was du auch im echten Leben bekommst. Ich hab keine Lust, eine Version von mir zu verkaufen, die besser klingt als die echte. Die echte ist eigentlich ganz okay.",
                    "\(i1) ist mir wirklich wichtig – nicht weil es gut klingt, sondern weil ich mich damit seit Jahren beschäftige. Fake-Interessen hab ich keine, und Fake-Gespräche kosten mich Energie. Ich mag Menschen, die auch einfach sie selbst sind.",
                    "Echte Gespräche > perfekte Inszenierung. Ich hab keine Angst vor unbequemen Themen, schlechten Tagen oder ehrlichen Antworten. Wenn du das genauso siehst und keine Lust auf Dating-Bingo hast: schreib mir."
                ]
            } else if isMedium {
                return [
                    "Kein Filter, keine Rolle – einfach ich. Was du hier liest, ist das, was du auch im echten Leben bekommst.",
                    "\(i1) ist mir wirklich wichtig – nicht weil es gut klingt, sondern weil es mich tatsächlich interessiert. Fake-Gespräche kosten mich Energie.",
                    "Echte Gespräche > perfekte Inszenierung. Wenn du keine Lust auf Dating-Bingo hast: schreib mir."
                ]
            }
            return [
                "Kein Filter, kein Rolle – einfach ich.",
                "\(i1) ist mir wichtig. Fake nicht.",
                "Echte Gespräche > perfekte Inszenierung."
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

    private func fallbackVibes(context: HooksInput? = nil) -> [String] {
        var base = ["Kaffee & ehrliche Gespräche", "Abendspaziergang mit Snacks", "Flohmarkt-Date", "Kino & Diskussion danach", "Sonnenuntergang-Spot", "Buchhandlung stöbern", "Street Food erkunden", "Kletterpark-Challenge"]
        if let i1 = context?.interests.first {
            base.insert("\(i1)-Abend zu zweit", at: 0)
        }
        if let i2 = context?.interests.dropFirst().first {
            base.insert("Spontanes \(i2)-Date", at: 1)
        }
        return Array(base.prefix(8))
    }
}
