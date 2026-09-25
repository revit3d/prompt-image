import SwiftUI

struct PhotoIndexingSummaryView: View {
    let store: PhotoIndexingStore
    let beforeStarting: () -> Void
    @State private var confirmsRebuild = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Подготовка к поиску")
                    .font(.headline)
                Spacer()
                controls
                Menu {
                    Button("Перестроить индекс") { confirmsRebuild = true }
                } label: {
                    Label("Действия с индексом", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .disabled(store.isBusy || store.phase == .waitingForLibrary || store.summary.totalCount == 0)
            }

            if store.phase == .preparing || store.phase == .waitingForLibrary {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(statusDescription)
                }
            } else {
                ProgressView(
                    value: Double(store.summary.embeddingCount + store.summary.ocrCount),
                    total: Double(max(1, store.summary.totalCount * 2))
                )
                .accessibilityLabel("Подготовка фотографий к поиску")
                Text(statusDescription)
            }

            Text("Готово: \(store.summary.completeCount) из \(store.summary.totalCount)")
            Text("Изображения: \(store.summary.embeddingCount) · Текст: \(store.summary.ocrCount)")
                .foregroundStyle(.secondary)
            if store.summary.pendingCount > 0 {
                Text("В очереди: \(store.summary.pendingCount)")
                    .foregroundStyle(.secondary)
            }
            if store.summary.downloadRequiredCount > 0 {
                Text("Недоступны без загрузки из iCloud: \(store.summary.downloadRequiredCount)")
                    .foregroundStyle(.secondary)
            }
            if store.summary.failedCount > 0 {
                Text("Не удалось обработать: \(store.summary.failedCount)")
                    .foregroundStyle(.secondary)
            }
            if let message = store.message {
                Text(message)
                    .foregroundStyle(.secondary)
            }
            if store.followsLibraryChanges {
                Text("Новые и изменённые снимки обрабатываются автоматически. После возврата в приложение повторно проверяются снимки, ранее доступные только в iCloud.")
                    .foregroundStyle(.secondary)
            }

            if store.summary.failedCount > 0 || store.summary.downloadRequiredCount > 0 {
                Button("Повторить пропущенные") {
                    beforeStarting()
                    store.retry()
                }
                .disabled(store.isBusy || store.wantsToRun || store.phase == .waitingForLibrary)
                .accessibilityIdentifier("retryPhotoIndexing")
            }

            Text("Обработка выполняется на iPhone, пока приложение открыто. Прогресс сохраняется. Фотографии из iCloud не загружаются.")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .buttonStyle(.bordered)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("photoIndexingSummary")
        .confirmationDialog("Перестроить индекс?", isPresented: $confirmsRebuild, titleVisibility: .visible) {
            Button("Перестроить") {
                beforeStarting()
                store.rebuild()
            }
        } message: {
            Text("Сохранённые результаты будут заменены повторной обработкой. Это может занять время. Фотографии останутся в медиатеке.")
        }
    }

    @ViewBuilder
    private var controls: some View {
        if store.wantsToRun || store.followsLibraryChanges {
            Button("Пауза") { store.pause() }
                .disabled(store.phase == .pausing)
                .accessibilityIdentifier("pausePhotoIndexing")
        } else if store.isBusy {
            ProgressView().controlSize(.small)
                .accessibilityLabel("Завершение текущей обработки")
        } else if store.phase == .failed || store.summary.totalCount > 0 {
            Button(startLabel) {
                beforeStarting()
                store.start()
            }
            .disabled(store.phase == .waitingForLibrary || store.phase == .preparing)
            .accessibilityIdentifier("startPhotoIndexing")
        }
    }

    private var startLabel: String {
        if store.phase == .failed { return "Повторить" }
        return store.summary.embeddingCount + store.summary.ocrCount > 0 ? "Продолжить" : "Начать"
    }

    private var statusDescription: String {
        switch store.phase {
        case .waitingForLibrary: return "Обновление медиатеки…"
        case .preparing: return "Проверка сохранённого прогресса…"
        case .ready: return "Можно начать подготовку фотографий."
        case .indexing:
            switch store.currentStage {
            case .embedding: return "Анализ изображения…"
            case .ocr: return "Распознавание текста…"
            case nil: return "Подготовка следующей фотографии…"
            }
        case .pausing: return "Завершение текущей обработки…"
        case .paused: return "На паузе. Можно продолжить с сохранённого места."
        case .finished:
            return store.summary.completeCount == store.summary.totalCount
                ? "Все доступные фотографии обработаны."
                : "Обработка завершена. Есть пропущенные фотографии."
        case .failed: return "Не удалось продолжить подготовку."
        }
    }
}
