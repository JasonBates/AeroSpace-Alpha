import AppBundle
import SwiftUI

// This file is shared between SPM and xcode project

@main
struct AeroSpaceApp: App {
    @StateObject var viewModel = TrayMenuModel.shared
    @StateObject var messageModel = MessageModel.shared
    @Environment(\.openWindow) var openWindow: OpenWindowAction

    init() {
        initAppBundle()
    }

    var body: some Scene {
        menuBar(viewModel: viewModel)
        getMessageWindow(messageModel: messageModel)
            .onChange(of: messageModel.message) { message in
                if message != nil {
                    openWindow(id: messageWindowId)
                }
            }
            .commands {
                // AeroSpace takes the keystrokes on a workspace a close left empty (takeKeystrokesForEmptyWorkspace),
                // where Cmd-Q or Cmd-H meant for the vanished window would quit or hide AeroSpace. Quit stays in the menu bar menu
                CommandGroup(replacing: .appTermination) {}
                CommandGroup(replacing: .appVisibility) {}
            }
    }
}
