import Photos
import SwiftUI
import UIKit

/// Opens a local Photos rendition at a useful zoom resolution without requesting
/// the unbounded original. The existing image provider never downloads from iCloud.
struct ZoomablePhotoView: View {
    let photo: LibraryPhoto
    @Environment(\.scenePhase) private var scenePhase
    @State private var loader: PhotoImageLoader
    @State private var retry = 0
    @State private var command = PhotoZoomCommand(sequence: 0, action: .fit)

    init(photo: LibraryPhoto, provider: any PhotoImageProviding) {
        self.photo = photo
        _loader = State(initialValue: PhotoImageLoader(provider: provider))
    }

    var body: some View {
        ZStack {
            Color.black
            switch loader.result {
            case .image(let image):
                PhotoZoomSurface(image: image, command: command)
                    .overlay(alignment: .bottom) {
                        HStack(spacing: 20) {
                            zoomButton("Уменьшить", symbol: "minus.magnifyingglass", action: .zoomOut)
                            zoomButton("Вписать в экран", symbol: "arrow.down.right.and.arrow.up.left", action: .fit)
                            zoomButton("Увеличить", symbol: "plus.magnifyingglass", action: .zoomIn)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding()
                    }
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
        .task(id: Request(photo: photo, retry: retry, isActive: scenePhase == .active)) {
            guard scenePhase == .active else {
                loader.cancel()
                return
            }
            loader.load(
                photo: photo,
                targetSize: PhotoZoomLayout.requestSize(for: photo),
                contentMode: .aspectFit
            )
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { loader.cancel() }
        }
        .onDisappear { loader.cancel() }
    }

    private func zoomButton(_ title: String, symbol: String, action: PhotoZoomAction) -> some View {
        Button {
            command = PhotoZoomCommand(sequence: command.sequence + 1, action: action)
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(title)
        .tint(.white)
    }

    private func placeholder(symbol: String, title: String, message: String) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: symbol).font(.largeTitle).accessibilityHidden(true)
                Text(title).font(.headline)
                Text(message).foregroundStyle(.secondary)
                Button("Повторить") { retry += 1 }.buttonStyle(.bordered)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    private struct Request: Equatable {
        let photo: LibraryPhoto
        let retry: Int
        let isActive: Bool
    }
}

nonisolated enum PhotoZoomLayout {
    // A 16 MP RGBA rendition is about 64 MB before framework overhead. The long
    // edge limit also bounds exceptionally tall screenshots and panoramas. These
    // are rendition request bounds, not a cap on all framework allocations.
    static let maximumPixelCount: Double = 16_000_000
    static let maximumDimension: Double = 8_192

    static func requestSize(for photo: LibraryPhoto) -> CGSize {
        guard photo.pixelWidth > 0, photo.pixelHeight > 0 else {
            return CGSize(width: 2_048, height: 2_048)
        }
        let width = Double(photo.pixelWidth)
        let height = Double(photo.pixelHeight)
        let scale = min(
            1,
            maximumDimension / max(width, height),
            sqrt(maximumPixelCount / (width * height))
        )
        return CGSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))
    }
}

nonisolated enum PhotoZoomAction {
    case zoomIn, zoomOut, fit
}

nonisolated struct PhotoZoomCommand {
    let sequence: Int
    let action: PhotoZoomAction
}

private struct PhotoZoomSurface: UIViewRepresentable {
    let image: UIImage
    let command: PhotoZoomCommand

    func makeUIView(context: Context) -> PhotoZoomScrollView {
        PhotoZoomScrollView()
    }

    func updateUIView(_ view: PhotoZoomScrollView, context: Context) {
        view.display(image)
        view.perform(command)
    }
}

/// UIKit owns the gesture state. SwiftUI updates only replace a changed image or
/// deliver a new explicit command, so ordinary redraws cannot reset a user's pan.
@MainActor
final class PhotoZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let photoView = UIImageView()
    private var fittedBounds = CGSize.zero
    private var isFitting = false
    private var lastCommandSequence: Int?

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        delegate = self
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        photoView.contentMode = .scaleAspectFit
        photoView.isAccessibilityElement = false
        addSubview(photoView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        isAccessibilityElement = true
        accessibilityLabel = "Фотография"
        accessibilityTraits = [.image, .adjustable]
        accessibilityHint = "Доступны действия увеличения, уменьшения и возврата к целому снимку."
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Увеличить", target: self, selector: #selector(accessibleZoomIn)),
            UIAccessibilityCustomAction(name: "Уменьшить", target: self, selector: #selector(accessibleZoomOut)),
            UIAccessibilityCustomAction(name: "Вписать в экран", target: self, selector: #selector(accessibleFit))
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ image: UIImage) {
        guard photoView.image !== image else { return }
        photoView.image = image
        fitImage()
    }

    func perform(_ command: PhotoZoomCommand) {
        guard lastCommandSequence != command.sequence else { return }
        lastCommandSequence = command.sequence
        changeZoom(command.action, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isFitting else { return }
        if fittedBounds != bounds.size {
            fitImage()
        } else {
            centerImage()
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { photoView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !isFitting else { return }
        centerImage()
        updateAccessibilityValue()
    }

    func changeZoom(_ action: PhotoZoomAction, animated: Bool) {
        guard photoView.image != nil, bounds.width > 0, bounds.height > 0 else { return }
        switch action {
        case .fit:
            setZoomScale(minimumZoomScale, animated: animated)
        case .zoomIn:
            zoomAroundCenter(to: min(maximumZoomScale, zoomScale * 2), animated: animated)
        case .zoomOut:
            zoomAroundCenter(to: max(minimumZoomScale, zoomScale / 2), animated: animated)
        }
    }

    /// `point` is in image coordinates, keeping the tapped detail under the zoom.
    func toggleZoom(at point: CGPoint, animated: Bool) {
        if zoomScale > minimumZoomScale * 1.05 {
            changeZoom(.fit, animated: animated)
        } else {
            zoom(to: min(maximumZoomScale, minimumZoomScale * 3), around: point, animated: animated)
        }
    }

    override func accessibilityIncrement() { changeZoom(.zoomIn, animated: false) }
    override func accessibilityDecrement() { changeZoom(.zoomOut, animated: false) }

    private func fitImage() {
        guard !isFitting, let image = photoView.image,
              image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        isFitting = true
        fittedBounds = bounds.size
        minimumZoomScale = 0.000_001
        maximumZoomScale = 1
        setZoomScale(1, animated: false)
        photoView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size

        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        // Permit at least native image-point scale for long screenshots; a fixed
        // multiplier alone would leave very tall screenshots too narrow to read.
        maximumZoomScale = max(1, fit * 6, bounds.width / image.size.width)
        minimumZoomScale = fit
        setZoomScale(fit, animated: false)
        centerImage()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        isFitting = false
        updateAccessibilityValue()
    }

    private func centerImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
    }

    private func zoomAroundCenter(to scale: CGFloat, animated: Bool) {
        let center = photoView.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: self)
        zoom(to: scale, around: center, animated: animated)
    }

    private func zoom(to scale: CGFloat, around point: CGPoint, animated: Bool) {
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                          width: size.width, height: size.height)
        zoom(to: rect, animated: animated)
    }

    private func updateAccessibilityValue() {
        let percent = Int((zoomScale / max(minimumZoomScale, 0.000_001) * 100).rounded())
        accessibilityValue = "Масштаб \(percent)%"
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        toggleZoom(at: recognizer.location(in: photoView), animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func accessibleZoomIn() -> Bool {
        changeZoom(.zoomIn, animated: false)
        return true
    }

    @objc private func accessibleZoomOut() -> Bool {
        changeZoom(.zoomOut, animated: false)
        return true
    }

    @objc private func accessibleFit() -> Bool {
        changeZoom(.fit, animated: false)
        return true
    }
}
