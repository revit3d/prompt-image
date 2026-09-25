import SwiftUI

struct PhotoOCRView: View {
    let photo: LibraryPhoto
    @Bindable var store: PhotoOCRStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Распознавание русского и английского текста на фотографии или скриншоте.")
                    Text("Обработка происходит на iPhone. Текст не сохраняется и очищается при закрытии этого экрана или переходе из приложения.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if store.isWorking {
                        HStack {
                            ProgressView(progressLabel)
                            Spacer()
                            if !store.isCancelling {
                                Button("Отмена") { store.cancel() }
                                    .accessibilityIdentifier("cancelPhotoOCR")
                            }
                        }
                    } else {
                        Button(store.result == nil && store.sourceFailure == nil && store.message == nil
                               ? "Начать распознавание" : "Распознать снова") {
                            store.start()
                        }
                        .disabled(scenePhase != .active)
                        .accessibilityIdentifier("startPhotoOCR")
                    }

                    if let failure = store.sourceFailure {
                        switch failure {
                        case .requiresDownload:
                            Label("Нужна загрузка из iCloud", systemImage: "icloud.and.arrow.down")
                            Text("Откройте снимок в приложении «Фото» и дождитесь загрузки, затем попробуйте снова. PromptImage не загружает фотографии из сети.")
                                .foregroundStyle(.secondary)
                        case .unavailable:
                            Label("Фотография недоступна", systemImage: "exclamationmark.circle")
                            Text("Снимок мог измениться или стать недоступным. Откройте его из медиатеки ещё раз и повторите распознавание.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let message = store.message {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("photoOCRError")
                    }
                }

                if let result = store.result {
                    Section("Распознанный текст") {
                        if result.lines.isEmpty {
                            Label("Текст не найден", systemImage: "text.magnifyingglass")
                            Text("На снимке может не быть читаемого текста. Мелкие или размытые надписи распознаются не всегда.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(result.text)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("recognizedPhotoText")
                        }
                    }
                }
            }
            .navigationTitle("Текст на фото")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть", systemImage: "xmark") {
                        store.deactivate()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if scenePhase == .active { store.activate(for: photo) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.activate(for: photo) }
            else { store.deactivate() }
        }
        .onDisappear { store.deactivate() }
    }

    private var progressLabel: String {
        if store.isCancelling { return "Завершение отмены…" }
        return store.operation == .loading ? "Чтение фотографии…" : "Распознавание текста…"
    }
}
