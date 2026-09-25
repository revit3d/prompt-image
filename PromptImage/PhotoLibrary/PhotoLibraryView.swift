import Photos
import SwiftUI

struct PhotoLibraryView: View {
    @Bindable var library: PhotoLibraryStore
    let showAccess: () -> Void
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Доступ", systemImage: "lock.shield", action: showAccess)
                }
            }
        }
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
