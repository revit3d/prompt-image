import ImageIO
import SwiftUI

/// A developer-installed public corpus, separate from the user's Photos library.
struct RetrievalDemoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = RetrievalDemoStore()
    @State private var text = ""
    @State private var language = QueryLanguageChoice.automatic
    @State private var selectedMatch: RetrievalDemoMatch?
    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Поиск по открытой тестовой коллекции. Она хранится отдельно от ваших личных фотографий. Все вычисления выполняются на iPhone.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    preparation
                    if model.isPrepared { query }
                    if let message = model.message {
                        Text(message).foregroundStyle(.secondary)
                            .accessibilityIdentifier("retrievalDemoError")
                    }
                    if let result = model.result { matches(result) }
                }
                .padding()
            }
            .navigationTitle("Тест поиска")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть", systemImage: "xmark") {
                        model.close()
                        dismiss()
                    }
                }
            }
            .sheet(item: $selectedMatch) { match in
                RetrievalDemoViewer(match: match)
            }
        }
        .onAppear {
            if scenePhase == .active { model.activate() }
        }
        .onChange(of: text) { _, _ in model.queryChanged() }
        .onChange(of: language) { _, _ in model.queryChanged() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.activate() }
            else { model.deactivate() }
        }
        .onDisappear { model.close() }
    }

    @ViewBuilder
    private var preparation: some View {
        if model.operation == .loading {
            ProgressView(model.isCancelling ? "Остановка…" : "Проверка коллекции…")
        } else if let summary = model.summary {
            VStack(alignment: .leading, spacing: 10) {
                Text("Изображений в коллекции: \(summary.imageCount)").font(.headline)
                if model.isPrepared {
                    Label("Коллекция готова к поиску", systemImage: "checkmark.circle")
                } else if model.operation == .indexing {
                    ProgressView(value: Double(model.completedImages), total: Double(max(1, model.totalImages)))
                    Text(model.isCancelling ? "Остановка…" : "Подготовлено: \(model.completedImages) из \(model.totalImages)")
                    Button("Отмена") { model.cancel() }.disabled(model.isCancelling)
                } else {
                    Button("Подготовить \(summary.imageCount) изображений") { model.prepare() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("prepareRetrievalDemo")
                }
                Text("Подготовка нужна после открытия этого экрана. При сворачивании приложения незавершённая подготовка останавливается; её нужно запустить сначала.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else if !model.isWorking {
            Button("Проверить коллекцию снова") { model.load() }
                .buttonStyle(.bordered)
        }
    }

    private var query: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Язык описания", selection: $language) {
                Text("Автоматически").tag(QueryLanguageChoice.automatic)
                Text("Русский").tag(QueryLanguageChoice.russian)
                Text("English").tag(QueryLanguageChoice.english)
            }
            .pickerStyle(.menu)
            TextField("Опишите, что хотите найти", text: $text, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("retrievalDescription")
            if let examples = model.summary?.queries, !examples.isEmpty {
                Menu("Примеры описаний") {
                    ForEach(examples) { example in
                        Button(example.text) {
                            text = example.text
                            language = example.language == .russian ? .russian : .english
                        }
                    }
                }
            }
            if model.operation == .searching {
                HStack {
                    ProgressView(model.isCancelling ? "Остановка…" : "Поиск…")
                    Spacer()
                    Button("Отмена") { model.cancel() }.disabled(model.isCancelling)
                }
            } else {
                Button("Найти изображения") { model.search(text, language: language) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("searchRetrievalDemo")
            }
            Text("Для коротких или смешанных описаний выберите язык вручную.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func matches(_ result: RetrievalDemoSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if result.englishText != result.originalText.trimmingCharacters(in: .whitespacesAndNewlines) {
                Text("Описание для поиска: \(result.englishText)")
                    .font(.subheadline).textSelection(.enabled)
                    .accessibilityIdentifier("retrievalEnglishDescription")
            }
            Text("Ближайшие изображения").font(.headline)
            Text("Порядок отражает сходство с описанием. Подходящего изображения в коллекции может не быть.")
                .font(.footnote).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(result.matches.enumerated()), id: \.element.id) { index, match in
                    Button { selectedMatch = match } label: {
                        RetrievalDemoImage(url: match.imageURL, isThumbnail: true)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(alignment: .bottomLeading) {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.white)
                                    .padding(6).background(.black.opacity(0.65), in: Capsule())
                                    .padding(5)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Результат \(index + 1)")
                    .accessibilityHint("Открыть изображение")
                }
            }
        }
    }
}

private struct RetrievalDemoViewer: View {
    let match: RetrievalDemoMatch
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RetrievalDemoImage(url: match.imageURL, isThumbnail: false)
                .background(.black)
                .navigationTitle("Тестовое изображение")
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

/// ImageIO decodes only the display-sized bitmap on a worker task. Invisible
/// cells release it, and task cancellation prevents a late decode from restoring it.
private struct RetrievalDemoImage: View {
    let url: URL
    let isThumbnail: Bool
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: CGImage?
    @State private var failed = false
    @State private var generation = UUID()

    var body: some View {
        GeometryReader { geometry in
            let request = Request(
                url: url,
                maximumPixelSize: max(1, min(4096, Int((max(geometry.size.width, geometry.size.height) * displayScale).rounded(.up)))),
                isActive: scenePhase == .active
            )
            ZStack {
                Color.secondary.opacity(0.12)
                if let image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: isThumbnail ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Не удалось открыть изображение")
                } else {
                    ProgressView().accessibilityLabel("Загрузка изображения")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .task(id: request) {
                image = nil
                failed = false
                let generation = UUID()
                self.generation = generation
                guard request.isActive else { return }
                let decode = Task.detached(priority: .userInitiated) { Self.decode(request) }
                let decoded = await withTaskCancellationHandler {
                    await decode.value
                } onCancel: {
                    decode.cancel()
                }
                guard !Task.isCancelled, self.generation == generation else { return }
                image = decoded
                failed = decoded == nil
            }
            .onDisappear {
                generation = UUID()
                image = nil
            }
        }
    }

    private nonisolated struct Request: Equatable, Sendable {
        let url: URL
        let maximumPixelSize: Int
        let isActive: Bool
    }

    private nonisolated static func decode(_ request: Request) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(request.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: request.maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard !Task.isCancelled else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
    }
}
