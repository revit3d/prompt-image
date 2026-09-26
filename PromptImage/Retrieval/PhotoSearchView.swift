import Photos
import SwiftUI

struct PhotoSearchView: View {
    let library: PhotoLibraryStore
    @Bindable var store: PhotoSearchStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var queryIsFocused: Bool
    @State private var scrollPosition = ScrollPosition(edge: .top)
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    query
                    indexStatus
                    results
                }
                .padding()
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: Double.self) { geometry in
                Double(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, offset in
                store.recordScrollOffset(offset)
            }
            .onChange(of: store.resultContext) { _, context in
                if context == nil { scrollPosition.scrollTo(edge: .top) }
            }
            .navigationTitle("Поиск фотографий")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть", systemImage: "xmark") {
                        store.deactivate()
                        dismiss()
                    }
                }
            }
            .fullScreenCover(item: Binding(get: { store.selectedPhoto }, set: { _ in store.dismissPhoto() }),
                             onDismiss: restoreResultsPosition) { photo in
                PhotoSearchViewer(photo: photo, provider: library.images, snippet: store.snippets[photo.id])
                    .id(library.imageRevision)
            }
        }
        .onAppear { if scenePhase == .active { store.activate() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.activate() }
            else { store.deactivate() }
        }
        .onDisappear {
            // Opening an original does not discard the query/results underneath.
            if store.selectedPhoto == nil { store.deactivate() }
        }
    }

    private var query: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Режим поиска", selection: $store.mode) {
                Text("По описанию и тексту").tag(PhotoSearchMode.combined)
                Text("Текст на фото").tag(PhotoSearchMode.textOnly)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("photoSearchMode")

            TextField(store.mode == .textOnly ? "Слова на фотографии" : "Опишите, что хотите найти",
                      text: $store.text, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($queryIsFocused)
                .submitLabel(.search)
                .onSubmit { submit() }
                .accessibilityIdentifier("photoSearchQuery")

            if store.mode == .combined {
                Picker("Язык описания", selection: $store.language) {
                    Text("Автоматически").tag(QueryLanguageChoice.automatic)
                    Text("Русский").tag(QueryLanguageChoice.russian)
                    Text("English").tag(QueryLanguageChoice.english)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("photoSearchLanguage")
                Text("Для короткого или смешанного описания выберите язык вручную.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Введите слова из изображения. Все слова должны встретиться в распознанном тексте; перевод не нужен.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            HStack {
                Button("Найти фотографии", systemImage: "magnifyingglass", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || !store.currentIndex.isReady)
                    .accessibilityIdentifier("submitPhotoSearch")
                if store.isWorking {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Поиск")
                    Button("Отмена") { store.cancel() }
                }
            }
        }
    }

    @ViewBuilder
    private var indexStatus: some View {
        let state = store.currentIndex
        if !state.isReady {
            Label(state.message ?? "Обновляем медиатеку. Поиск станет доступен после подготовки индекса.",
                  systemImage: state.message == nil ? "hourglass" : "exclamationmark.circle")
                .font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("photoSearchIndexStatus")
            if state.message != nil { preparationButton }
        } else if (store.mode == .textOnly ? state.summary.ocrCount : state.summary.embeddingCount + state.summary.ocrCount) == 0 {
            ContentUnavailableView {
                Label(store.mode == .textOnly ? "Текст ещё не подготовлен" : "Пока нечего искать",
                      systemImage: "photo.badge.magnifyingglass")
            } description: {
                Text("Вернитесь к фотографиям и запустите «Подготовку к поиску». Уже готовые снимки будут доступны сразу.")
            } actions: { preparationButton }
            .accessibilityIdentifier("photoSearchEmptyIndex")
        } else {
            let coverage = store.resultContext?.coverage ?? PhotoSearchCoverage(summary: state.summary, mode: store.mode)
            VStack(alignment: .leading, spacing: 6) {
                Label(coverage.title, systemImage: coverage.isComplete ? "checkmark.circle" : "circle.lefthalf.filled")
                Text(coverage.detail)
                if store.resultContext != nil {
                    Text("Готовность фотографий на момент поиска.")
                }
                if !coverage.isComplete {
                    Text("Продолжите подготовку в галерее, чтобы найти больше совпадений.")
                    preparationButton
                }
                if library.access.status == .limited {
                    Text("Поиск охватывает только фотографии, к которым вы разрешили доступ.")
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
            .accessibilityIdentifier(coverage.isComplete ? "photoSearchCompleteIndex" : "photoSearchPartialIndex")
        }
    }

    private var preparationButton: some View {
        Button("К подготовке фотографий") {
            store.deactivate()
            dismiss()
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var results: some View {
        switch store.phase {
        case .results:
            VStack(alignment: .leading, spacing: 12) {
                Text(store.mode == .combined ? "Ближайшие совпадения" : "Найдено по тексту")
                    .font(.headline)
                if store.mode == .combined {
                    Text("Результаты отсортированы по сходству с запросом. Подходящего снимка среди них может не быть.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(store.matches.enumerated()), id: \.element.photo.id) { offset, match in
                        let snippet = store.snippets[match.photo.id]
                        Button { store.select(match.photo) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                PhotoImageView(photo: match.photo, isThumbnail: true, provider: library.images)
                                    .id(library.imageRevision)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                Label(match.recognizedText == nil ? "По описанию" : "Текст на фото",
                                      systemImage: match.recognizedText == nil ? "photo" : "text.viewfinder")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let snippet {
                                    PhotoSearchSnippetText(snippet: snippet)
                                        .font(.footnote).lineLimit(4)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Результат \(offset + 1). \(snippet?.text ?? (match.recognizedText == nil ? "По описанию" : "Текст на фото"))")
                        .accessibilityHint("Открыть фотографию")
                    }
                }
                .accessibilityIdentifier("photoSearchResults")
                if store.matches.count == 50 {
                    Text("Показаны первые 50 результатов. Уточните запрос, чтобы сузить поиск.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        case .noMatches:
            ContentUnavailableView {
                Label(store.mode == .textOnly ? "Текст не найден" : "Совпадений пока нет",
                      systemImage: "magnifyingglass")
            } description: {
                Text(store.mode == .textOnly
                     ? "В подготовленных фотографиях нет всех указанных слов. Проверьте написание или используйте меньше слов."
                     : "Попробуйте другое описание или подготовьте больше фотографий.")
            }
            .accessibilityIdentifier("photoSearchNoMatches")
        case .failed:
            if let message = store.message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("photoSearchError")
            }
        case .searching:
            Text("Ищем фотографии…").foregroundStyle(.secondary)
        case .waitingForIndex:
            if store.currentIndex.isReady {
                Text("Медиатека обновилась. Нажмите «Найти фотографии», чтобы повторить поиск.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        case .idle, .emptyIndex:
            EmptyView()
        }
    }

    private func submit() {
        queryIsFocused = false
        store.search()
    }

    private func restoreResultsPosition() {
        if let offset = store.takeViewerReturnOffset() {
            scrollPosition.scrollTo(y: offset)
        }
    }
}

private struct PhotoSearchViewer: View {
    let photo: LibraryPhoto
    let provider: any PhotoImageProviding
    let snippet: PhotoSearchSnippet?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZoomablePhotoView(photo: photo, provider: provider)
                    .background(.black)
                    .safeAreaInset(edge: .bottom) {
                        if let snippet {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Совпадение в распознанном тексте").font(.caption).foregroundStyle(.secondary)
                                    PhotoSearchSnippetText(snippet: snippet).font(.footnote)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                            }
                            // Keep the image and zoom controls reachable in
                            // landscape and at accessibility text sizes.
                            .frame(height: min(160, geometry.size.height * 0.3))
                            .background(.ultraThinMaterial)
                        }
                    }
            }
            .navigationTitle("Фотография")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct PhotoSearchSnippetText: View {
    let snippet: PhotoSearchSnippet

    var body: some View { Text(attributedText) }

    private var attributedText: AttributedString {
        snippet.segments.reduce(into: AttributedString()) { result, segment in
            var part = AttributedString(segment.text)
            if segment.isMatch { part.inlinePresentationIntent = .stronglyEmphasized }
            result.append(part)
        }
    }
}
