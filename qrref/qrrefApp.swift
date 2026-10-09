//
//  qrrefApp.swift
//  qrref
//
//  Created by Петр Ломакин on 09.10.2026.
//

import SwiftUI

@main
struct qrrefApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.theme.colorScheme)
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: model.appBecameActive()
                    case .background: model.appEnteredBackground()
                    default: break
                    }
                }
        }
    }
}
