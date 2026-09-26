import Testing
import UIKit
@testable import PromptImage

@MainActor
struct PhotoZoomTests {
    @Test(arguments: [
        CGSize(width: 8_064, height: 6_048),
        CGSize(width: 6_048, height: 8_064),
        CGSize(width: 1_170, height: 40_000),
        CGSize(width: 40_000, height: 1_170),
        CGSize(width: 1, height: 40_000)
    ])
    func largeSourcesHaveBoundedRenditionRequests(source: CGSize) {
        let target = PhotoZoomLayout.requestSize(for: photo(size: source))

        #expect(target.width >= 1 && target.height >= 1)
        #expect(target.width <= 8_192 && target.height <= 8_192)
        #expect(target.width * target.height <= 16_000_000)
        #expect(target.width <= source.width && target.height <= source.height)
        // Each edge may differ from the proportional size by one pixel after
        // rounding (or retaining the final pixel of an extreme panorama). Compare
        // normalized scales: projecting the rounded short edge onto a very long
        // edge incorrectly multiplies that permitted rounding error.
        let widthScale = target.width / source.width
        let heightScale = target.height / source.height
        let roundingTolerance = 1 / source.width + 1 / source.height
        #expect(abs(widthScale - heightScale) <= roundingTolerance)
    }

    @Test
    func modestPhotosKeepTheirSourceResolutionAndInvalidMetadataHasABoundedFallback() {
        #expect(PhotoZoomLayout.requestSize(for: photo(size: CGSize(width: 1_200, height: 900)))
                == CGSize(width: 1_200, height: 900))
        #expect(PhotoZoomLayout.requestSize(for: photo(size: CGSize(width: 0, height: -1)))
                == CGSize(width: 2_048, height: 2_048))
    }

    @Test
    func initiallyFitsAndCentersTheEntireImage() {
        let view = viewer(size: CGSize(width: 300, height: 500))
        view.display(image(size: CGSize(width: 1_000, height: 500)))
        view.layoutIfNeeded()

        #expect(abs(view.minimumZoomScale - 0.3) < 0.001)
        #expect(abs(view.zoomScale - 0.3) < 0.001)
        #expect(abs(view.contentSize.width - 300) < 0.01)
        #expect(abs(view.contentSize.height - 150) < 0.01)
        #expect(abs(view.contentInset.top - 175) < 0.01)
        #expect(abs(view.contentOffset.y + 175) < 0.01)
        #expect(view.accessibilityValue == "Масштаб 100%")
    }

    @Test
    func routineImageUpdatesKeepTheUsersZoomAndPan() {
        let view = viewer(size: CGSize(width: 300, height: 500))
        let original = image(size: CGSize(width: 1_000, height: 800))
        view.display(original)
        view.perform(PhotoZoomCommand(sequence: 0, action: .fit))
        view.setZoomScale(0.9, animated: false)
        view.setContentOffset(CGPoint(x: 230, y: 100), animated: false)
        view.layoutIfNeeded()
        let previousOffset = view.contentOffset

        view.display(original)
        view.perform(PhotoZoomCommand(sequence: 0, action: .fit))
        view.layoutIfNeeded()

        #expect(abs(view.zoomScale - 0.9) < 0.001)
        #expect(view.contentOffset == previousOffset)
    }

    @Test
    func changingTheViewportRefitsAndRecentersTheImage() {
        let view = viewer(size: CGSize(width: 300, height: 500))
        view.display(image(size: CGSize(width: 1_000, height: 500)))
        view.setZoomScale(1.2, animated: false)
        view.setContentOffset(CGPoint(x: 200, y: 60), animated: false)

        view.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        #expect(abs(view.zoomScale - 0.6) < 0.001)
        #expect(view.zoomScale == view.minimumZoomScale)
        #expect(abs(view.contentSize.width - 600) < 0.01)
        #expect(abs(view.contentSize.height - 300) < 0.01)
        #expect(abs(view.contentOffset.x) < 0.01)
        #expect(abs(view.contentOffset.y) < 0.01)
    }

    @Test
    func replacingAnImageCannotInheritAnOldZoomOrOffset() {
        let view = viewer(size: CGSize(width: 300, height: 500))
        view.display(image(size: CGSize(width: 1_000, height: 500)))
        view.setZoomScale(1.2, animated: false)
        view.setContentOffset(CGPoint(x: 200, y: 60), animated: false)

        view.display(image(size: CGSize(width: 200, height: 1_000)))
        view.layoutIfNeeded()

        #expect(abs(view.zoomScale - 0.5) < 0.001)
        #expect(abs(view.contentInset.left - 100) < 0.01)
        #expect(abs(view.contentOffset.x + 100) < 0.01)
        #expect(abs(view.contentOffset.y) < 0.01)
    }

    @Test
    func doubleTapZoomsIntoADetailAndThenReturnsToTheWholePhoto() {
        let view = viewer(size: CGSize(width: 300, height: 500))
        view.display(image(size: CGSize(width: 1_000, height: 800)))

        view.toggleZoom(at: CGPoint(x: 500, y: 400), animated: false)
        view.layoutIfNeeded()
        #expect(abs(view.zoomScale - view.minimumZoomScale * 3) < 0.001)
        #expect(view.contentSize.width > view.bounds.width)

        view.toggleZoom(at: CGPoint(x: 700, y: 600), animated: false)
        view.layoutIfNeeded()
        #expect(view.zoomScale == view.minimumZoomScale)
        #expect(abs(view.contentSize.width - 300) < 0.01)
        #expect(abs(view.contentOffset.x) < 0.01)
        #expect(abs(view.contentOffset.y + view.contentInset.top) < 0.01)
    }

    @Test
    func zoomButtonsAndAccessibilityActionsRespectTheScaleBounds() {
        let view = viewer(size: CGSize(width: 300, height: 500))
        view.display(image(size: CGSize(width: 1_000, height: 500)))

        view.accessibilityIncrement()
        #expect(abs(view.zoomScale - 0.6) < 0.001)
        #expect(view.accessibilityValue == "Масштаб 200%")
        for _ in 0..<10 { view.changeZoom(.zoomIn, animated: false) }
        #expect(abs(view.zoomScale - view.maximumZoomScale) < 0.001)
        for _ in 0..<10 { view.accessibilityDecrement() }
        #expect(view.zoomScale == view.minimumZoomScale)
        #expect(view.accessibilityCustomActions?.map(\.name) == ["Увеличить", "Уменьшить", "Вписать в экран"])
        #expect(view.accessibilityTraits.contains(.adjustable))
    }

    @Test
    func longScreenshotsCanBeZoomedToScreenWidth() {
        let view = viewer(size: CGSize(width: 390, height: 700))
        view.display(image(size: CGSize(width: 100, height: 3_000)))
        let scaleToFillWidth: CGFloat = 390 / 100

        #expect(view.maximumZoomScale >= scaleToFillWidth)
        view.setZoomScale(scaleToFillWidth, animated: false)
        view.layoutIfNeeded()

        #expect(abs(view.contentSize.width - 390) < 0.01)
        #expect(view.contentSize.height > view.bounds.height)
    }

    @Test
    func receivingAnImageBeforeLayoutFitsOnceTheViewportExists() {
        let view = PhotoZoomScrollView()
        view.display(image(size: CGSize(width: 1_000, height: 500)))

        view.frame = CGRect(x: 0, y: 0, width: 300, height: 500)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        #expect(abs(view.zoomScale - 0.3) < 0.001)
        #expect(abs(view.contentSize.width - 300) < 0.01)
    }

    private func viewer(size: CGSize) -> PhotoZoomScrollView {
        let view = PhotoZoomScrollView()
        view.frame = CGRect(origin: .zero, size: size)
        return view
    }

    private func image(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func photo(size: CGSize) -> LibraryPhoto {
        LibraryPhoto(id: "zoom-test", creationDate: nil, modificationDate: nil,
                     pixelWidth: Int(size.width), pixelHeight: Int(size.height))
    }
}
