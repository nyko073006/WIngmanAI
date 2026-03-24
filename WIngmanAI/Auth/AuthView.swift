//
//  AuthView.swift
//  WIngmanAI
//
//  Created by Nyko on 31.01.26.
//

import SwiftUI

struct AuthView: View {
    @EnvironmentObject var auth: AuthService

    @State private var email = ""
    @State private var password = ""
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 12) {
            Text("Wingman").font(.largeTitle).bold()

            TextField("Email", text: $email)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            SecureField("Password", text: $password)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            Button("Sign Up") {
                Task {
                    do { try await auth.signUp(email: email, password: password) }
                    catch { errorText = String(describing: error) }
                }
            }

            Button("Sign In") {
                Task {
                    do { try await auth.signIn(email: email, password: password) }
                    catch { errorText = String(describing: error) }
                }
            }

            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding()
    }
}
