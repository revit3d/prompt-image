import SwiftUI

/// A small query verification surface; photo retrieval is introduced in step 3.4.
struct QuerySetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = QuerySetupStore()
    @State private var text = ""
    @State private var language = QueryLanguageChoice.automatic
    @State private var request: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section("Перевод на iPhone") {
                    switch model.availability {
                    case nil:
                        ProgressView("Проверка модели…")
                    case .ready:
                        Label("Русский → Английский", systemImage: "checkmark.circle")
                        Text("Модель перевода встроена в приложение. Интернет и отдельная загрузка языков не нужны.")
                    case .modelUnavailable:
                        Text("Модель перевода недоступна. Переустановите приложение или используйте английское описание.")
                    }
                    Text("Ваши описания обрабатываются на устройстве и не отправляются на сервер.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Язык описания", selection: $language) {
                        Text("Автоматически").tag(QueryLanguageChoice.automatic)
                        Text("Русский").tag(QueryLanguageChoice.russian)
                        Text("English").tag(QueryLanguageChoice.english)
                    }
                    TextField("Например, красная машина у дома", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("queryDescription")
                    if model.isProcessing {
                        HStack {
                            ProgressView("Подготовка описания…")
                            Spacer()
                            Button("Отмена") { invalidateQuery() }
                        }
                    } else {
                        Button("Проверить описание") { request = UUID() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("prepareQuery")
                    }
                    if let message = model.queryMessage {
                        Text(message).foregroundStyle(.secondary)
                            .accessibilityIdentifier("queryError")
                    }
                    if let result = model.result {
                        Label("Описание подготовлено", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                        LabeledContent(result.sourceLanguage == .russian ? "Перевод" : "Описание") {
                            Text(result.englishText).textSelection(.enabled)
                        }
                        .accessibilityIdentifier("preparedQuery")
                    }
                } header: {
                    Text("Проверка описания")
                } footer: {
                    Text("Пока можно проверить язык и перевод описания. Поиск фотографий появится на следующем шаге прототипа. Для коротких или смешанных описаний выберите язык вручную.")
                }
            }
            .navigationTitle("Язык поиска")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .task(id: request) {
            guard request != nil else { return }
            await model.prepareQuery(text, language: language)
        }
        .onChange(of: text) { _, _ in invalidateQuery() }
        .onChange(of: language) { _, _ in invalidateQuery() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { invalidateQuery() }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await model.refreshAvailability() }
        }
        .onDisappear {
            model.deactivate()
            Task { await model.unload() }
        }
    }

    private func invalidateQuery() {
        request = nil
        model.clearQuery()
    }
}
