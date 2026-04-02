# Wingman - Produktidee & Leitfaden

## 1. Produktidee & Positionierung
**Name:** Wingman
**Typ:** iOS‑Dating‑App (SwiftUI) + Supabase‑Backend
**Kern‑USP:**
Wingman ist die Dating‑App, die dich zu klaren, ehrlichen, respektvollen Interaktionen führt – kein endloses Swipen, kein anonymes Ghosting, kein Blind‑Dating‑Drama.
**Positionierung in einem Satz:**
Wingman ist die Dating‑App für junge Erwachsene, die echte Verbindungen aufbauen wollen, ohne ihre Zeit und ihre Nerven in Endlos‑Chats und unsichtbaren Abbrüchen zu verlieren.
**Kern‑Werte:**
- Echtes Dating, keine Fake‑Accounts, keine KI‑Bots.
- AI als transparenter Assistenz‑Layer, nicht als versteckter Protagonist.
- Vertrauen, klare Boundaries und respektvolle, saubere Abschlüsse statt Ghosting.
**Zielgruppe:**
- 18–32‑jährige, urban, digital‑affin, datenbewusst, überwiegend in Deutschland/Europa.
- Müde von Swipe‑Fatigue, Ghosting, schlechten Matches, Fake‑Profilen.
- Sucht eine Plattform, die Dating‑Verhalten optimiert, nicht nur „Match‑Anzahl“.

## 2. Was Wingman NICHT ist (Constraints)
Damit Wingman klar bleibt, definieren wir diese Grenzen strikt:
- Keine Fake‑Accounts, keine gefakteten Matches, keine gefälschten „online“‑Users.
- Keine KI‑Personas oder Bots, die für Nutzer chatten oder emotionale Rollen spielen.
- Generierte Konversationen nur auf expliziten Wunsch: KI liefert nur Text‑Vorschläge, die der Nutzer bewusst ersetzt, bestätigt oder löscht.
- AI ist ein transparenter Assistenz‑Layer für: Onboarding‑Hilfe, Profil‑Optimierung, Icebreaker‑Vorschläge, Antwort‑Inspiration, Feedback‑Analyse. Alle AI‑Funktionen sind klar sichtbar gekennzeichnet, können komplett deaktiviert werden und dürfen nie wie ein „echter User“ erscheinen.

## 3. Produkt‑USP & Kern‑Mechaniken
Wingman ist kein „Tinder‑Klon mit AI‑Gimmick“.
Wingman ist ein Behavior‑Design‑System für Dating:
Du bekommst nicht mehr Matches, aber bessere Signal‑Klarheit.
Du bekommst weniger Chat‑Noise, dafür klare, ehrliche Abschlüsse.
Du bekommst KI‑Unterstützung, nicht KI‑Übernahme deiner Identität.

1. **Anti‑Ghosting & Closure‑Flow:** Inaktive Chats aktivieren einen klaren Abschluss‑Flow mit vorgefertigten, höflichen Texten. Reduziert Unsicherheit, Scham und „Dating‑Burnout“.
2. **Boundaries‑Settings:** Nutzer legen Grenzen fest, die im Profil ersichtlich sind. Macht Präferenzen sichtbar, senkt Missverständnisse.
3. **AI‑Co‑Pilot (nicht Bot):** AI‑Hilfe bei Profil‑Erstellung, Icebreakern, Antwort‑Vorschlägen, Feedback‑Analyse. Unterstützt, ohne zu sprechen; erhöht Sicherheit.
4. **Feedback‑ & Growth‑Layer:** Nach Dates (opt‑in) anonymes, konstruktives Feedback, kein öffentliches „Rating“.

## 4. Zielsetzung & Produkt‑Ziele
**Kurzfristig (MVP‑Fokus):**
- Stabile, skalierbare Dating‑App auf SwiftUI + Supabase.
- Verlässliche Auth (E‑Mail, Social‑Sign‑In, 18+‑Gate).
- Multi‑Step‑Onboarding.
- Profil‑System mit Fotos, Bio, Interessen, Prompts, Standort‑Basis.
- Swipe → Match → Chat.
- Reporting, Blocking, einfache Moderation.
- MVP‑Mechaniken: Closure‑Flow, Boundary‑Settings, AI‑Co‑Pilot für Onboarding & Profil.

**Mittelfristig:**
- "Anti-Ghosting" als Kern-Brand etablieren. Vertrauenssignale (z.B. Closure-Rate) aufbauen.

**Langfristig:**
- Monetarisierung durch Extended AI-Assist, Insights, Priority-Discovery, Video-Profile.

## 5. Technische Architektur & Stack
- **Frontend (iOS/SwiftUI):** Ordnerstruktur: App, Auth, Core, Onboarding, Profile, UI.
- **Backend (Supabase):** Postgres (Profiles, Matches, Chats, Reports), Realtime Chat, Storage für Profilbilder, RPC-Edge-Functions für AI.

## 6. Produkt‑Anforderungen: Kern‑Features
- **Auth/Onboarding:** Multiphase, 18+ Gate, Basisdaten (Fotos, Bio mit AI-Hilfe, Interessen, Prompts, Boundary-Settings).
- **Profilstruktur:** Transparente Boundaries, AI Profile-Review.
- **Swipe Flow:** Links/Rechts mit Boundary-Matching.
- **Chat/Closure-Flow:** Inaktivitäts-Erkennung, vorgefertigte höfliche Abschlüsse.
- **Date/Feedback Loop:** Date-Vorschläge, ehrliches privates Feedback zur Selbstverbesserung.

## 7. Safety, Vertrauen & UX
- Reportings, Blockings. "Clean Dating" Narrativ. Klar sichtbare Transparenz-Badges ("18+ Verified", "Boundary-Clear").
- UX ist kontrolliert, nicht chaotisch. Kein Gamification-Lärm.
- Klare Entscheidungs-Regeln: Reduziert es Ghosting? Ist die KI transparent? Wenn nein, wird es nicht eingebaut!
