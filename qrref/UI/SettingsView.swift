//
//  SettingsView.swift
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var serverInvalid = false
    @State private var confirmNewKey = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Адрес сервера") {
                    TextField("https://qrref.io", text: $server)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if serverInvalid {
                        Text("Укажите адрес вида https://qrref.io").font(.caption).foregroundStyle(.red)
                    }
                }

                Section("Тема") {
                    Picker("Тема", selection: $model.theme) {
                        ForEach(ThemeMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    Button("Новый ключ", role: .destructive) { confirmNewKey = true }
                } footer: {
                    Text("Создаст новый QR-код. Старый перестанет принимать данные, а открытый чат будет закрыт.")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        if model.setServerURL(server) { dismiss() } else { serverInvalid = true }
                    }
                }
            }
            .confirmationDialog("Создать новый ключ?", isPresented: $confirmNewKey, titleVisibility: .visible) {
                Button("Создать", role: .destructive) {
                    model.regenerateKey()
                    dismiss()
                }
            }
        }
        .onAppear { server = model.serverURL }
        .onChange(of: server) { serverInvalid = false }
    }
}
