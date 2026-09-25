import Photos
import SwiftUI

struct PhotoImageView: View {
    let photo: LibraryPhoto
    let isThumbnail: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var loader: PhotoImageLoader
    @State private var retry = 0

    init(photo: LibraryPhoto, isThumbnail: Bool, provider: any PhotoImageProviding) {
        self.photo = photo
        self.isThumbnail = isThumbnail
        _loader = State(initialValue: PhotoImageLoader(provider: provider))
    }

    var body: some View {
        GeometryReader { geometry in
            let request = ImageRequest(
                photo: photo,
                width: max(1, Int((geometry.size.width * displayScale).rounded(.up))),
                height: max(1, Int((geometry.size.height * displayScale).rounded(.up))),
                isThumbnail: isThumbnail,
                retry: retry
            )

            ZStack {
                Color.secondary.opacity(0.12)
                switch loader.result {
                case .image(let image):
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: isThumbnail ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                case .cloudOnly:
                    placeholder(
                        symbol: "icloud",
                        title: "Фото недоступно на iPhone",
                        message: "Откройте снимок в приложении «Фото», чтобы загрузить его из iCloud. PromptImage не загружает фотографии из сети."
                    )
                case .unavailable:
                    placeholder(
                        symbol: "photo.badge.exclamationmark",
                        title: "Не удалось открыть фото",
                        message: "Снимок мог быть удалён или доступ к нему изменился."
                    )
                case nil:
                    ProgressView()
                        .accessibilityLabel("Загрузка фотографии")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .task(id: request) {
                loader.load(
                    photo: request.photo,
                    targetSize: CGSize(width: request.width, height: request.height),
                    contentMode: isThumbnail ? .aspectFill : .aspectFit
                )
            }
            .onDisappear { loader.cancel() }
        }
    }

    @ViewBuilder
    private func placeholder(symbol: String, title: String, message: String) -> some View {
        if isThumbnail {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityLabel(title)
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: symbol)
                        .font(.largeTitle)
                        .accessibilityHidden(true)
                    Text(title).font(.headline)
                    Text(message).foregroundStyle(.secondary)
                    Button("Повторить") { retry += 1 }
                        .buttonStyle(.bordered)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
    }

    private struct ImageRequest: Equatable {
        let photo: LibraryPhoto
        let width: Int
        let height: Int
        let isThumbnail: Bool
        let retry: Int
    }
}
