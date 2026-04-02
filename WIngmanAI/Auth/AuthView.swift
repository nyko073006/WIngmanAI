import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @EnvironmentObject var auth: AppAuthService

    var initialSignUp: Bool = false

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var showConsent = false
    @State private var showResetSheet = false

    @Environment(\.colorScheme) private var colorScheme
    private enum Field: Hashable { case email, password }
    @FocusState private var focusedField: Field?

    init(initialSignUp: Bool = false) {
        self.initialSignUp = initialSignUp
        _isSignUp = State(initialValue: initialSignUp)
    }

    private let brand = Color(.sRGB, red: 0xE8/255.0, green: 0x60/255.0, blue: 0x7A/255.0, opacity: 1.0)

    private var emailIsValid: Bool {
        let t = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [brand.opacity(0.18), Color.purple.opacity(0.10), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 40)

                    // Logo
                    Image("colored-logo-ohne-schrift")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 110)

                    // Sign in / Sign up toggle
                    Picker("", selection: $isSignUp) {
                        Text("Anmelden").tag(false)
                        Text("Registrieren").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 32)

                    VStack(spacing: 14) {
                        TextField("E-Mail", text: $email)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .padding()
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                            .focused($focusedField, equals: .email)
                            .onSubmit { focusedField = .password }

                        SecureField("Passwort", text: $password)
                            .textContentType(isSignUp ? .newPassword : .password)
                            .padding()
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                            .focused($focusedField, equals: .password)
                            .onSubmit {
                                if isSignUp {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    showConsent = true
                                } else if emailIsValid && !password.isEmpty {
                                    Task {
                                        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
                                        await auth.signIn(email: e, password: password)
                                    }
                                }
                            }
                    }
                    .padding(.horizontal, 24)

                    if !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !emailIsValid {
                        Text("Ungültige E-Mail-Adresse.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                    }

                    if isSignUp && !password.isEmpty && password.count < 6 {
                        Text("Passwort muss mindestens 6 Zeichen haben.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                    }

                    Button {
                        if isSignUp {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showConsent = true
                        } else {
                            Task {
                                let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
                                await auth.signIn(email: e, password: password)
                            }
                        }
                    } label: {
                        HStack {
                            if auth.isBusy { ProgressView().tint(.white) }
                            Text(auth.isBusy ? "..." : (isSignUp ? "Weiter" : "Anmelden"))
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(colors: [brand, brand.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(auth.isBusy || email.isEmpty || password.isEmpty || !emailIsValid || (isSignUp && password.count < 6))
                    .padding(.horizontal, 24)

                    if !isSignUp {
                        Button("Passwort vergessen?") {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showResetSheet = true
                        }
                        .font(.subheadline)
                        .foregroundStyle(brand.opacity(0.8))
                    }

                    // Divider
                    HStack(spacing: 10) {
                        Rectangle().fill(Color(.systemGray4)).frame(height: 0.5)
                        Text("oder").font(.caption).foregroundStyle(.secondary)
                        Rectangle().fill(Color(.systemGray4)).frame(height: 0.5)
                    }
                    .padding(.horizontal, 24)

                    // Apple Sign In
                    SignInWithAppleButton(
                        isSignUp ? .signUp : .signIn,
                        onRequest: { request in
                            request.requestedScopes = [.fullName, .email]
                        },
                        onCompletion: { result in
                            Task { await auth.handleAppleResult(result) }
                        }
                    )
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 24)

                    // Google Sign In
                    Button {
                        Task { await auth.signInWithGoogle() }
                    } label: {
                        GoogleSignInLabel()
                            .frame(height: 52)
                    }
                    .padding(.horizontal, 24)

                    if let err = auth.error {
                        VStack(spacing: 4) {
                            Text(err.title).font(.subheadline).fontWeight(.semibold)
                            Text(err.message).font(.footnote).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    }

                    Spacer(minLength: 40)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $showResetSheet) {
            ForgotPasswordSheet(brand: brand, prefillEmail: email)
                .presentationDetents([.height(340)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .sheet(isPresented: $showConsent) {
            ConsentSheet(brand: brand) {
                showConsent = false
                Task {
                    let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
                    await auth.signUp(email: e, password: password)
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Forgot Password Sheet

private struct ForgotPasswordSheet: View {
    let brand: Color
    let prefillEmail: String

    @EnvironmentObject var auth: AppAuthService
    @Environment(\.dismiss) private var dismiss

    @State private var resetEmail: String = ""
    @State private var didSend = false

    private var emailIsValid: Bool {
        resetEmail.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Handle
            Capsule()
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 24)

            if didSend {
                VStack(spacing: 14) {
                    Image(systemName: "envelope.badge.checkmark.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(brand)
                    Text("Link gesendet!")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Text("Schau in dein Postfach und folge dem Link zum Zurücksetzen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Schließen") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(brand)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 32)
            } else {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Text("Passwort vergessen?")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                        Text("Gib deine E-Mail ein – wir schicken dir einen Reset-Link.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    TextField("E-Mail-Adresse", text: $resetEmail)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 24)
                        .onSubmit {
                            if emailIsValid && !auth.isBusy {
                                Task {
                                    await auth.resetPassword(email: resetEmail.trimmingCharacters(in: .whitespacesAndNewlines))
                                    withAnimation { didSend = true }
                                }
                            }
                        }

                    Button {
                        Task {
                            await auth.resetPassword(email: resetEmail.trimmingCharacters(in: .whitespacesAndNewlines))
                            withAnimation { didSend = true }
                        }
                    } label: {
                        HStack {
                            if auth.isBusy { ProgressView().tint(.white) }
                            Text(auth.isBusy ? "Sende…" : "Link senden")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            emailIsValid
                                ? AnyShapeStyle(LinearGradient(colors: [brand, brand.opacity(0.8)], startPoint: .leading, endPoint: .trailing))
                                : AnyShapeStyle(Color.secondary.opacity(0.3))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(!emailIsValid || auth.isBusy)
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 16)
            }
        }
        .onAppear { resetEmail = prefillEmail }
    }
}

// MARK: - Consent Sheet

private struct ConsentSheet: View {
    let brand: Color
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    private let brandAlt = Color(.sRGB, red: 0xF5/255.0, green: 0x7C/255.0, blue: 0x5B/255.0, opacity: 1.0)

    @State private var agb = false
    @State private var datenschutz = false
    @State private var respekt = false
    @State private var newsletter = false

    private var allRequired: Bool { agb && datenschutz && respekt }
    private var allChecked: Bool { agb && datenschutz && respekt && newsletter }

    private func toggleAll() {
        let next = !allChecked
        agb = next; datenschutz = next; respekt = next; newsletter = next
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(brand)
                    .padding(.top, 28)
                Text("Fast geschafft!")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Text("Bitte lies und akzeptiere unsere Bedingungen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.bottom, 24)

            // Checkboxes
            VStack(spacing: 0) {
                // Allem zustimmen
                consentRow(
                    checked: allChecked,
                    label: "Allem zustimmen",
                    required: false,
                    bold: true
                ) { toggleAll() }

                Divider().padding(.leading, 56).opacity(0.4)

                consentRowWithLink(
                    checked: agb,
                    prefix: "Ich habe die ",
                    linkText: "AGB & Nutzungsbedingungen",
                    linkURL: "https://wingmanapp.de/agb",
                    suffix: " gelesen und akzeptiert.",
                    required: true
                ) {
                    agb.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }

                Divider().padding(.leading, 56).opacity(0.4)

                consentRowWithLink(
                    checked: datenschutz,
                    prefix: "Ich habe die ",
                    linkText: "Datenschutzerklärung",
                    linkURL: "https://wingmanapp.de/datenschutz",
                    suffix: " gelesen und akzeptiert.",
                    required: true
                ) {
                    datenschutz.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }

                Divider().padding(.leading, 56).opacity(0.4)

                consentRow(checked: respekt, label: "Ich verpflichte mich, andere Nutzer respektvoll und fair zu behandeln.", required: true) {
                    respekt.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }

                Divider().padding(.leading, 56).opacity(0.4)

                consentRow(checked: newsletter, label: "Ich möchte die neuesten WingmanAI-News per E-Mail erhalten.", required: false) {
                    newsletter.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.gray.opacity(0.12), lineWidth: 1))
            .padding(.horizontal, 20)

            Spacer(minLength: 24)

            // CTA
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onConfirm()
            } label: {
                Text("Account erstellen")
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(
                        allRequired
                            ? AnyShapeStyle(LinearGradient(colors: [brand, brandAlt], startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color.secondary.opacity(0.3))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: allRequired ? brand.opacity(0.35) : .clear, radius: 12, y: 6)
            }
            .disabled(!allRequired)
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
            .animation(.easeInOut(duration: 0.2), value: allRequired)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private func linkedText(prefix: String, linkText: String, linkURL: String, suffix: String) -> AttributedString {
        var str = AttributedString(prefix + linkText + suffix)
        if let range = str.range(of: linkText), let url = URL(string: linkURL) {
            str[range].link = url
            str[range].underlineStyle = .single
        }
        return str
    }

    private func consentRowWithLink(checked: Bool, prefix: String, linkText: String, linkURL: String, suffix: String, required: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(checked ? brand : Color(.systemGray5))
                        .frame(width: 24, height: 24)
                    if checked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: checked)
                .padding(.top, 1)

                HStack(alignment: .top, spacing: 4) {
                    Text(linkedText(prefix: prefix, linkText: linkText, linkURL: linkURL, suffix: suffix))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .tint(brand)
                    if required {
                        Text("*")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(brand)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private func consentRow(checked: Bool, label: String, required: Bool, bold: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(checked ? brand : Color(.systemGray5))
                        .frame(width: 24, height: 24)
                    if checked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: checked)
                .padding(.top, 1)

                HStack(alignment: .top, spacing: 4) {
                    Text(label)
                        .font(bold ? .system(.subheadline, design: .rounded).weight(.semibold) : .subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if required {
                        Text("*")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(brand)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Welcome / Landing Screen

struct WelcomeView: View {
    @EnvironmentObject var auth: AppAuthService
    @State private var authDest: AuthDest? = nil
    @Environment(\.colorScheme) private var colorScheme

    private let brand    = Color(.sRGB, red: 0xE8/255.0, green: 0x60/255.0, blue: 0x7A/255.0, opacity: 1.0)
    private let brandAlt = Color(.sRGB, red: 0xF5/255.0, green: 0x7C/255.0, blue: 0x5B/255.0, opacity: 1.0)

    enum AuthDest: Identifiable {
        case signIn, signUp
        var id: Int { hashValue }
    }

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [brand.opacity(0.22), brandAlt.opacity(0.10), Color(.systemBackground)],
                startPoint: .topLeading, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                Image("colored-logo-ohne-schrift")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                    .padding(.bottom, 20)

                VStack(spacing: 10) {
                    Text("Wingman")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    Text("Echtes Dating mit deinem AI-Wingman")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, 40)

                // Feature rows — grouped card
                VStack(spacing: 0) {
                    featureRow(icon: "sparkles",                         text: "AI-unterstützte Bio & Hooks")
                    Divider().padding(.leading, 68).opacity(0.4)
                    featureRow(icon: "heart.fill",                       text: "Smarte Matches in deiner Nähe")
                    Divider().padding(.leading, 68).opacity(0.4)
                    featureRow(icon: "bubble.left.and.bubble.right.fill", text: "Echtzeit-Wingman im Chat")
                }
                .background(Color(.systemBackground).opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.gray.opacity(0.12), lineWidth: 1))
                .padding(.horizontal, 24)
                .padding(.bottom, 48)

                Spacer()

                // CTAs
                VStack(spacing: 12) {
                    // Apple Sign In — must appear before other options (Apple guideline)
                    SignInWithAppleButton(
                        .signUp,
                        onRequest: { request in
                            request.requestedScopes = [.fullName, .email]
                        },
                        onCompletion: { result in
                            Task { await auth.handleAppleResult(result) }
                        }
                    )
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    // Google Sign In
                    Button {
                        Task { await auth.signInWithGoogle() }
                    } label: {
                        GoogleSignInLabel()
                            .frame(height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }

                    HStack(spacing: 10) {
                        Rectangle().fill(Color(.systemGray4)).frame(height: 0.5)
                        Text("oder per E-Mail").font(.caption).foregroundStyle(.secondary)
                        Rectangle().fill(Color(.systemGray4)).frame(height: 0.5)
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        authDest = .signUp
                    } label: {
                        Text("Mit E-Mail registrieren")
                            .font(.system(.body, design: .rounded).weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(
                                LinearGradient(colors: [brand, brandAlt],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .shadow(color: brand.opacity(0.4), radius: 14, y: 7)
                    }
                    .buttonStyle(.plain)

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        authDest = .signIn
                    } label: {
                        Text("Ich habe schon einen Account")
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                            .foregroundStyle(brand)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(brand.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .sheet(item: $authDest) { dest in
            AuthView(initialSignUp: dest == .signUp)
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(brand)
                .frame(width: 40, height: 40)
                .background(brand.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(text)
                .font(.system(.subheadline, design: .rounded).weight(.medium))
            Spacer()
        }
        .padding(16)
    }
}

// MARK: - Google Sign In Button Label

struct GoogleSignInLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            // Google "G" logo drawn with SwiftUI
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 22, height: 22)
                Text("G")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(red: 0.26, green: 0.52, blue: 0.96))
            }
            Text("Mit Google fortfahren")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(colorScheme == .dark ? .white : Color(.label))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            colorScheme == .dark
                ? Color(.systemGray5)
                : Color.white
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
    }
}
