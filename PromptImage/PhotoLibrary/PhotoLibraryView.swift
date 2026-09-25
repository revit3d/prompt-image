import Photos
import SwiftUI

struct PhotoLibraryView: View {
    @Bindable var library: PhotoLibraryStore
    let showAccess: () -> Void
    let showQuerySetup: () -> Void
    let showRetrievalDemo: () -> Void
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(library.access.status == .limited
                             ? "Доступ к выбранным фотографиям" : "Полный доступ разрешён")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("Фото: \(library.photos.count)")
                                .font(.headline)
                            if library.isLoading {
                                ProgressView().controlSize(.small)
                                    .accessibilityLabel("Обновление медиатеки")
                            }
                        }
                    }
                    .padding(.horizontal, 16)

                    if !library.photos.isEmpty {
                        PhotoAvailabilitySummary(scan: library.availability)
                            .padding(.horizontal, 16)
                    }

                    if library.photos.isEmpty {
                        if !library.isLoading {
                            ContentUnavailableView {
                                Label("Нет доступных фотографий", systemImage: "photo.on.rectangle")
                            } description: {
                                Text(library.access.status == .limited
                                     ? "Выберите фотографии в настройках доступа."
                                     : "Добавьте снимки в медиатеку приложения «Фото».")
                            } actions: {
                                if library.access.status == .limited {
                                    Button("Изменить доступ", action: showAccess)
                                }
                            }
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(library.photos) { photo in
                                Button {
                                    library.selectedPhoto = photo
                                } label: {
                                    PhotoImageView(photo: photo, isThumbnail: true, provider: library.images)
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay(alignment: .bottomTrailing) {
                                            if let result = library.availability.results[photo.id] {
                                                availabilityBadge(result)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(photo.accessibilityDescription)
                                .accessibilityHint("Открыть фотографию")
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Фотографии")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Тест поиска", systemImage: "magnifyingglass", action: showRetrievalDemo)
                        Button("Язык поиска", systemImage: "character.bubble", action: showQuerySetup)
                    } label: {
                        Label("Поиск", systemImage: "magnifyingglass")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Доступ", systemImage: "lock.shield", action: showAccess)
                }
            }
        }
    }

    private func availabilityBadge(_ result: PhotoAvailability) -> some View {
        let symbol: String
        let label: String
        switch result {
        case .local:
            symbol = "checkmark.circle.fill"
            label = "Данные доступны на iPhone"
        case .requiresDownload:
            symbol = "icloud.and.arrow.down"
            label = "Требуется загрузка из iCloud"
        case .unavailable:
            symbol = "exclamationmark.circle.fill"
            label = "Не удалось проверить"
        }
        return Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.7), in: Capsule())
            .padding(5)
            .accessibilityLabel(label)
    }
}

private struct PhotoAvailabilitySummary: View {
    let scan: PhotoAvailabilityScan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Доступность на iPhone")
                    .font(.headline)
                Spacer()
                if scan.isRunning {
                    Button("Пауза") { scan.pause() }
                } else if scan.uncheckedCount == 0 && scan.hasStarted {
                    Button("Перепроверить") { scan.restart() }
                } else {
                    Button(scan.hasStarted ? "Продолжить" : "Проверить") { scan.start() }
                }
            }
            if scan.hasStarted {
                ProgressView(value: Double(scan.checkedCount), total: Double(max(1, scan.totalCount)))
                Text("Проверено: \(scan.checkedCount) из \(scan.totalCount)")
                Text("На iPhone: \(scan.localCount) · Пропущено: \(scan.skippedCount)")
                if scan.skippedCount > 0 {
                    Text("Нужна загрузка: \(scan.downloadRequiredCount) · Не удалось проверить: \(scan.unavailableCount)")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Проверка покажет, какие снимки доступны без загрузки из iCloud.")
                    .foregroundStyle(.secondary)
            }
            Text("Не проверено: \(scan.uncheckedCount)")
                .foregroundStyle(.secondary)
            Text("Фотографии не загружаются из сети. Результаты показывают доступность на момент проверки.")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .buttonStyle(.bordered)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct PhotoViewer: View {
    let photo: LibraryPhoto
    let provider: any PhotoImageProviding
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PhotoImageView(photo: photo, isThumbnail: false, provider: provider)
                .background(.black)
                .accessibilityLabel(photo.accessibilityDescription)
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

private extension LibraryPhoto {
    var accessibilityDescription: String {
        guard let creationDate else { return "Фотография" }
        let date = creationDate.formatted(
            .dateTime.day().month(.wide).year().locale(Locale(identifier: "ru"))
        )
        return "Фотография, \(date)"
    }
}
