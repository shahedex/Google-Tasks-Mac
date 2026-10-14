import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep running in the menu bar
    }
}

@main
enum Entry {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--screenshots") {
            let dir = CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : "docs/screenshots"
            MainActor.assumeIsolated { ScreenshotRenderer.run(outputDirectory: dir) }
        } else {
            GoogleTasksApp.main()
        }
    }
}

struct GoogleTasksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Google Tasks", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 460)
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(model.phase != .signedIn)
            }
            CommandGroup(replacing: .help) {
                Button("Open Google Tasks on the Web") {
                    NSWorkspace.shared.open(URL(string: "https://tasks.google.com")!)
                }
            }
            CommandMenu("Account") {
                Button("Sign Out") { model.signOut() }
                    .disabled(model.phase != .signedIn)
                Button("Reset OAuth Client…") { model.resetClientConfig() }
                    .disabled(model.phase == .needsClientConfig)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(count: model.phase == .signedIn ? model.incompleteCount(listID: model.selectedListID) : nil)
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .needsClientConfig: SetupView()
            case .signedOut: SignInView()
            case .signedIn: MainView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Menu bar icon with the number of incomplete tasks in the selected list.
struct MenuBarLabel: View {
    let count: Int?

    var body: some View {
        if let count, count > 0 {
            Image(systemName: "checklist")
            Text("\(count)")
        } else {
            Image(systemName: "checklist")
        }
    }
}
