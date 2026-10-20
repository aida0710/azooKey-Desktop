import Core
import SwiftUI

@MainActor
struct HomebrewUpdateView: View {
    @ObservedObject private var controller: HomebrewUpdateController
    @State private var confirmsUpdate = false

    init() {
        self.init(controller: .shared)
    }

    init(controller: HomebrewUpdateController) {
        self.controller = controller
    }

    var body: some View {
        Section {
            Text(Localization.text("support.update.description"))
            if let messageKey = controller.messageKey {
                if controller.isPreviousResult {
                    Text(Localization.text("support.update.previousResult")).font(.caption)
                }
                Text(Localization.text(messageKey))
            }
            HStack {
                Button(Localization.text("support.update.start")) { confirmsUpdate = true }
                    .disabled(!controller.canStart)
                if controller.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            if controller.canReopenTerminal {
                Button(Localization.text("support.update.reopenTerminal")) { controller.reopenTerminal() }
            }
        } header: {
            Text(Localization.text("support.update.title"))
        }
        .alert(Localization.text("support.update.confirm.title"), isPresented: $confirmsUpdate) {
            Button(Localization.text("support.update.confirm.action")) { controller.start() }
            Button(Localization.text("support.update.cancel"), role: .cancel) {}
        } message: {
            Text(Localization.text("support.update.confirm.message"))
        }
    }
}
