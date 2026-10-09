//
//  ContentView.swift
//  qrref
//
//  Created by Петр Ломакин on 09.10.2026.
//

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.screen) {
            Tab("Прием на это устройство", systemImage: "arrow.down.circle", value: AppScreen.receive) {
                NavigationStack {
                    if model.roomID != nil { ChatView() } else { ReceiveView() }
                }
                .toolbar(model.roomID == nil ? .visible : .hidden, for: .tabBar)
            }
            Tab("Отправка с этого устройства", systemImage: "paperplane", value: AppScreen.send) {
                NavigationStack {
                    if model.roomID != nil { ChatView() } else { SendView() }
                }
                .toolbar(model.roomID == nil ? .visible : .hidden, for: .tabBar)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast.text)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4, y: 2)
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
    }
}

#Preview {
    RootView().environment(AppModel())
}
