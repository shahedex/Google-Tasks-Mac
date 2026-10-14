import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// First run: collect the user's own Google OAuth "Desktop app" client.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var importError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Connect to Google Tasks", systemImage: "checklist")
                    .font(.largeTitle.bold())

                Text("This app talks to Google Tasks directly through Google's official API. Google requires each app to have an OAuth client, so you create one once (free, about 5 minutes).")
                    .foregroundStyle(.secondary)

                GroupBox("One-time setup in Google Cloud Console") {
                    VStack(alignment: .leading, spacing: 10) {
                        step(1, "Create a project", link: "https://console.cloud.google.com/projectcreate")
                        step(2, "Enable the Google Tasks API", link: "https://console.cloud.google.com/apis/library/tasks.googleapis.com")
                        step(3, "Configure the OAuth consent screen: User type \"External\", app name anything. Under Audience, add your Google account as a Test user. (Workspace accounts can choose \"Internal\" instead.)", link: "https://console.cloud.google.com/auth/overview")
                        step(4, "Create an OAuth client ID. Application type: Desktop app. Then download the JSON.", link: "https://console.cloud.google.com/auth/clients/create")
                        step(5, "Import the JSON below, or paste the Client ID and secret.", link: nil)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                HStack {
                    Button {
                        importJSON()
                    } label: {
                        Label("Import client JSON…", systemImage: "doc.badge.arrow.up")
                    }
                    .controlSize(.large)
                    if let importError {
                        Text(importError).foregroundStyle(.red).font(.callout)
                    }
                }

                Text("Or enter the values manually:").font(.headline).padding(.top, 4)
                Form {
                    TextField("Client ID", text: $clientID, prompt: Text("xxxx.apps.googleusercontent.com"))
                    SecureField("Client secret", text: $clientSecret)
                }
                .formStyle(.columns)

                Button("Save and continue") {
                    model.saveClientConfig(OAuthClientConfig(
                        clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                        clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
                .buttonStyle(.borderedProminent)
                .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)

                Text("Credentials and sign-in tokens are stored in your macOS Keychain and only ever sent to Google.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func step(_ n: Int, _ text: String, link: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.callout.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                if let link, let url = URL(string: link) {
                    Link("Open in browser ↗", destination: url).font(.callout)
                }
            }
        }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the client_secret_….json file you downloaded from Google Cloud Console"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let config = try OAuthClientConfig.fromGoogleJSON(try Data(contentsOf: url))
            model.saveClientConfig(config)
        } catch {
            importError = error.localizedDescription
        }
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checklist")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Google Tasks").font(.largeTitle.bold())
            Text("Sign in with the Google account you use on your phone.\nYour browser opens once for Google's consent screen.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if model.isSigningIn {
                ProgressView("Waiting for Google sign-in in your browser…")
                    .padding(.top, 6)
            } else {
                Button("Sign in with Google") { Task { await model.signIn() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Button("Use a different OAuth client") { model.resetClientConfig() }
                .buttonStyle(.link)
                .font(.footnote)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
