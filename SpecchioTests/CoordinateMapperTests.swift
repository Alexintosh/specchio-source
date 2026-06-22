import XCTest
@testable import Specchio

final class CoordinateMapperTests: XCTestCase {

    func testExactFit() {
        // View exactly matches phone screen size
        let mapper = CoordinateMapper(
            phoneScreenSize: CGSize(width: 390, height: 844),
            viewSize: CGSize(width: 390, height: 844)
        )
        XCTAssertEqual(mapper.scale, 1.0)
        let result = mapper.viewToPhone(CGPoint(x: 195, y: 422))
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, 195, accuracy: 0.001)
        XCTAssertEqual(result!.y, 422, accuracy: 0.001)
    }

    func testScaledDown() {
        // View is half the phone size
        let mapper = CoordinateMapper(
            phoneScreenSize: CGSize(width: 390, height: 844),
            viewSize: CGSize(width: 195, height: 422)
        )
        XCTAssertEqual(mapper.scale, 2.0)
        let result = mapper.viewToPhone(CGPoint(x: 97.5, y: 211))
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, 195, accuracy: 0.001)
        XCTAssertEqual(result!.y, 422, accuracy: 0.001)
    }

    func testOutOfBoundsReturnsNil() {
        let mapper = CoordinateMapper(
            phoneScreenSize: CGSize(width: 390, height: 844),
            viewSize: CGSize(width: 390, height: 844)
        )
        // Point outside the phone screen
        let result = mapper.viewToPhone(CGPoint(x: -10, y: 500))
        XCTAssertNil(result)
    }

    func testTopLeftCorner() {
        let mapper = CoordinateMapper(
            phoneScreenSize: CGSize(width: 390, height: 844),
            viewSize: CGSize(width: 390, height: 844)
        )
        let result = mapper.viewToPhone(CGPoint(x: 0, y: 0))
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, 0, accuracy: 0.001)
        XCTAssertEqual(result!.y, 0, accuracy: 0.001)
    }

    func testBottomRightCorner() {
        let mapper = CoordinateMapper(
            phoneScreenSize: CGSize(width: 390, height: 844),
            viewSize: CGSize(width: 390, height: 844)
        )
        let result = mapper.viewToPhone(CGPoint(x: 390, y: 844))
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, 390, accuracy: 0.001)
        XCTAssertEqual(result!.y, 844, accuracy: 0.001)
    }

    func testAspectRatioMismatchWithOffset() {
        // View is wider than phone aspect ratio - should have horizontal offset
        let mapper = CoordinateMapper(
            phoneScreenSize: CGSize(width: 390, height: 844),
            viewSize: CGSize(width: 800, height: 844)
        )
        // Phone fills height, letterboxed on sides
        XCTAssertTrue(mapper.offset.x > 0)
    }

    func testRotationNormalization() {
        XCTAssertEqual(InputSurfaceRotationMapping.normalizedRotation(0), 0)
        XCTAssertEqual(InputSurfaceRotationMapping.normalizedRotation(90), 90)
        XCTAssertEqual(InputSurfaceRotationMapping.normalizedRotation(450), 90)
        XCTAssertEqual(InputSurfaceRotationMapping.normalizedRotation(-90), 270)
    }

    func testAbsoluteDisplayPointMappingTracksScreenRotation() {
        XCTAssertEqual(
            InputSurfaceRotationMapping.phoneNormalizedPoint(displayX: 0.25, displayY: 0.75, rotationDegrees: 0),
            CGPoint(x: 0.25, y: 0.75)
        )
        XCTAssertEqual(
            InputSurfaceRotationMapping.phoneNormalizedPoint(displayX: 0.25, displayY: 0.75, rotationDegrees: 90),
            CGPoint(x: 0.75, y: 0.75)
        )
        XCTAssertEqual(
            InputSurfaceRotationMapping.phoneNormalizedPoint(displayX: 0.25, displayY: 0.75, rotationDegrees: 270),
            CGPoint(x: 0.25, y: 0.25)
        )
    }

    func testRelativeMouseDeltaMappingTracksScreenRotation() {
        let delta = CGPoint(x: 10, y: 20)

        XCTAssertEqual(
            InputSurfaceRotationMapping.relativePointerDelta(delta, rotationDegrees: 0),
            CGPoint(x: 10, y: 20)
        )
        XCTAssertEqual(
            InputSurfaceRotationMapping.relativePointerDelta(delta, rotationDegrees: 90),
            CGPoint(x: 20, y: -10)
        )
        XCTAssertEqual(
            InputSurfaceRotationMapping.relativePointerDelta(delta, rotationDegrees: 180),
            CGPoint(x: -10, y: -20)
        )
        XCTAssertEqual(
            InputSurfaceRotationMapping.relativePointerDelta(delta, rotationDegrees: 270),
            CGPoint(x: -20, y: 10)
        )
    }
}

final class EasyModeGeometryTests: XCTestCase {
    func testRotationCycleSkipsUpsideDownState() {
        XCTAssertEqual(EasyWindowVideoSizing.nextRotation(after: 0), 90)
        XCTAssertEqual(EasyWindowVideoSizing.nextRotation(after: 90), 270)
        XCTAssertEqual(EasyWindowVideoSizing.nextRotation(after: 270), 0)
        XCTAssertEqual(EasyWindowVideoSizing.nextRotation(after: 180), 0)
    }

    func testDisplayedPhoneSizeSwapsOnlyForSidewaysRotations() {
        let phoneSize = CGSize(width: 390, height: 844)

        XCTAssertEqual(
            EasyWindowVideoSizing.displayedPhoneSize(phoneScreenSize: phoneSize, rotationDegrees: 0),
            CGSize(width: 390, height: 844)
        )
        XCTAssertEqual(
            EasyWindowVideoSizing.displayedPhoneSize(phoneScreenSize: phoneSize, rotationDegrees: 90),
            CGSize(width: 844, height: 390)
        )
        XCTAssertEqual(
            EasyWindowVideoSizing.displayedPhoneSize(phoneScreenSize: phoneSize, rotationDegrees: 270),
            CGSize(width: 844, height: 390)
        )
    }

    func testRotationUsesPreviousSurfaceSizeAndInvertsWhenOrientationChanges() {
        let portraitSurface = CGSize(width: 300, height: 650)

        XCTAssertEqual(
            EasyWindowVideoSizing.surfaceSize(afterRotating: portraitSurface, from: 0, to: 90),
            CGSize(width: 650, height: 300)
        )
        XCTAssertEqual(
            EasyWindowVideoSizing.surfaceSize(afterRotating: CGSize(width: 650, height: 300), from: 90, to: 270),
            CGSize(width: 650, height: 300)
        )
        XCTAssertEqual(
            EasyWindowVideoSizing.surfaceSize(afterRotating: CGSize(width: 650, height: 300), from: 270, to: 0),
            CGSize(width: 300, height: 650)
        )
    }

    func testEffectiveTopChromeHeightFallsBackBeforeToolbarMeasurementArrives() {
        XCTAssertEqual(
            EasyWindowVideoSizing.effectiveTopChromeHeight(
                reportedTopChromeHeight: 0,
                contentHeight: 754,
                phoneSurfaceAvailableHeight: 650
            ),
            104,
            accuracy: 0.001
        )

        XCTAssertEqual(
            EasyWindowVideoSizing.effectiveTopChromeHeight(
                reportedTopChromeHeight: 112,
                contentHeight: 754,
                phoneSurfaceAvailableHeight: 650
            ),
            112,
            accuracy: 0.001
        )
    }

    func testEffectiveTopChromeHeightPrefersReportedControlBarWhenAvailable() {
        XCTAssertEqual(
            EasyWindowVideoSizing.effectiveTopChromeHeight(
                reportedTopChromeHeight: 44,
                contentHeight: 900,
                phoneSurfaceAvailableHeight: 650
            ),
            44,
            accuracy: 0.001
        )
    }

    func testStableTopChromeRetainsPreviousValueDuringTransientLayoutMismatch() {
        let measurement = EasyWindowVideoSizing.stableEffectiveTopChromeHeight(
            previousEffectiveTopChromeHeight: 104,
            reportedTopChromeHeight: 0,
            contentHeight: 494,
            phoneSurfaceAvailableHeight: 844
        )

        XCTAssertEqual(measurement.height, 104, accuracy: 0.001)
        XCTAssertEqual(measurement.source, .retainedDuringTransientLayout)
        XCTAssertNil(measurement.measuredHeight)
    }

    func testStableTopChromeRejectsImplausiblyLargeTransientMeasurement() {
        let measurement = EasyWindowVideoSizing.stableEffectiveTopChromeHeight(
            previousEffectiveTopChromeHeight: 104,
            reportedTopChromeHeight: 0,
            contentHeight: 900,
            phoneSurfaceAvailableHeight: 300
        )

        XCTAssertEqual(measurement.height, 104, accuracy: 0.001)
        XCTAssertEqual(measurement.source, .retainedDuringTransientLayout)
        XCTAssertEqual(measurement.measuredHeight ?? -1, 600, accuracy: 0.001)
    }

    func testStableTopChromeUsesReportedValueWhenAvailable() {
        let measurement = EasyWindowVideoSizing.stableEffectiveTopChromeHeight(
            previousEffectiveTopChromeHeight: 104,
            reportedTopChromeHeight: 44,
            contentHeight: 900,
            phoneSurfaceAvailableHeight: 650
        )

        XCTAssertEqual(measurement.height, 44, accuracy: 0.001)
        XCTAssertEqual(measurement.source, .reported)
        XCTAssertEqual(measurement.measuredHeight ?? -1, 250, accuracy: 0.001)
    }

    func testStableTopChromeUsesMeasuredValueBeforeControlBarReports() {
        let measurement = EasyWindowVideoSizing.stableEffectiveTopChromeHeight(
            previousEffectiveTopChromeHeight: nil,
            reportedTopChromeHeight: 0,
            contentHeight: 900,
            phoneSurfaceAvailableHeight: 650
        )

        XCTAssertEqual(measurement.height, 250, accuracy: 0.001)
        XCTAssertEqual(measurement.source, .measured)
        XCTAssertEqual(measurement.measuredHeight ?? -1, 250, accuracy: 0.001)
    }

    func testResizeDriverTracksDominantUserDelta() {
        let previous = CGSize(width: 300, height: 754)

        XCTAssertEqual(
            EasyWindowVideoSizing.resizeDriver(
                previousContentSize: previous,
                currentContentSize: CGSize(width: 460, height: 754)
            ),
            .width
        )
        XCTAssertEqual(
            EasyWindowVideoSizing.resizeDriver(
                previousContentSize: previous,
                currentContentSize: CGSize(width: 300, height: 900)
            ),
            .height
        )
        XCTAssertEqual(
            EasyWindowVideoSizing.resizeDriver(
                previousContentSize: previous,
                currentContentSize: CGSize(width: 460, height: 914),
                rotationDegrees: 0
            ),
            .height
        )
        XCTAssertEqual(
            EasyWindowVideoSizing.resizeDriver(
                previousContentSize: previous,
                currentContentSize: CGSize(width: 460, height: 914),
                rotationDegrees: 90
            ),
            .width
        )
    }

    func testWidthDrivenResizeGrowsHeightInsteadOfSnappingWidthBack() {
        let target = EasyWindowVideoSizing.targetContentSizeForResize(
            contentSize: CGSize(width: 460, height: 754),
            displayedPhoneSize: CGSize(width: 390, height: 844),
            topChromeHeight: 104,
            minimumContentWidth: 300,
            driver: .width
        )

        XCTAssertEqual(target.width, 460, accuracy: 0.001)
        XCTAssertEqual(target.height, 104 + (460 / (390.0 / 844.0)), accuracy: 0.001)
    }

    func testHeightDrivenResizeAdjustsWidthFromVideoHeight() {
        let target = EasyWindowVideoSizing.targetContentSizeForResize(
            contentSize: CGSize(width: 460, height: 900),
            displayedPhoneSize: CGSize(width: 390, height: 844),
            topChromeHeight: 104,
            minimumContentWidth: 300,
            driver: .height
        )

        XCTAssertEqual(target.width, (900 - 104) * (390.0 / 844.0), accuracy: 0.001)
        XCTAssertEqual(target.height, 900, accuracy: 0.001)
    }

    func testInitialVideoFrameResizeUsesActualFrameSize() {
        let target = EasyWindowVideoSizing.targetContentSizeForInitialVideoFrame(
            videoFrameSize: CGSize(width: 300, height: 500),
            topChromeHeight: 104,
            minimumContentSize: .zero
        )

        XCTAssertEqual(target.width, 300, accuracy: 0.001)
        XCTAssertEqual(target.height, 104 + 500, accuracy: 0.001)
    }

    func testInitialVideoFrameResizeKeepsAspectWhenMinimumWidthApplies() {
        let target = EasyWindowVideoSizing.targetContentSizeForInitialVideoFrame(
            videoFrameSize: CGSize(width: 200, height: 400),
            topChromeHeight: 104,
            minimumContentSize: CGSize(width: 300, height: 0)
        )

        XCTAssertEqual(target.width, 300, accuracy: 0.001)
        XCTAssertEqual(target.height, 104 + 600, accuracy: 0.001)
    }

    func testInitialVideoFrameClampUsesTotalNonVideoHeight() {
        let target = EasyWindowVideoSizing.targetContentSizeForInitialVideoFrame(
            videoFrameSize: CGSize(width: 884, height: 1920),
            topChromeHeight: 96,
            minimumContentSize: .zero
        )
        let clamped = EasyWindowVideoSizing.contentSizeByScalingDownToFit(
            target,
            topChromeHeight: 96,
            maximumContentSize: CGSize(width: 359, height: 823)
        )

        XCTAssertEqual(clamped.width, (823 - 96) * (884.0 / 1920.0), accuracy: 0.001)
        XCTAssertEqual(clamped.height, 823, accuracy: 0.001)
    }

    func testAspectCorrectContentSizeIsNotCorrectedBackToStaleSurface() {
        let widthDrivenTarget = EasyWindowVideoSizing.targetContentSizeForResize(
            contentSize: CGSize(width: 460, height: 754),
            displayedPhoneSize: CGSize(width: 390, height: 844),
            topChromeHeight: 104,
            minimumContentWidth: 300,
            driver: .width
        )

        XCTAssertTrue(
            EasyWindowVideoSizing.contentSizeMatchesVideoAspect(
                contentSize: widthDrivenTarget,
                displayedPhoneSize: CGSize(width: 390, height: 844),
                topChromeHeight: 104,
                minimumContentWidth: 300
            )
        )
        XCTAssertFalse(
            EasyWindowVideoSizing.contentSizeMatchesVideoAspect(
                contentSize: CGSize(width: 460, height: 754),
                displayedPhoneSize: CGSize(width: 390, height: 844),
                topChromeHeight: 104,
                minimumContentWidth: 300
            )
        )
    }

    func testRotationTargetContentSizeSwapsVideoAreaWhenOrientationChanges() {
        let target = EasyWindowVideoSizing.targetContentSizeAfterRotation(
            currentContentSize: CGSize(width: 390, height: 104 + 844),
            displayedPhoneSize: CGSize(width: 844, height: 390),
            topChromeHeight: 104,
            minimumContentSize: .zero,
            from: 0,
            to: 90
        )

        XCTAssertEqual(target.width, 844, accuracy: 0.001)
        XCTAssertEqual(target.height, 104 + 390, accuracy: 0.001)
    }

    func testRotationTargetContentSizeKeepsVideoAreaWhenOrientationDoesNotChange() {
        let target = EasyWindowVideoSizing.targetContentSizeAfterRotation(
            currentContentSize: CGSize(width: 844, height: 104 + 390),
            displayedPhoneSize: CGSize(width: 844, height: 390),
            topChromeHeight: 104,
            minimumContentSize: .zero,
            from: 90,
            to: 270
        )

        XCTAssertEqual(target.width, 844, accuracy: 0.001)
        XCTAssertEqual(target.height, 104 + 390, accuracy: 0.001)
    }

    func testOversizedLandscapeContentScalesDownToMaximumContentArea() {
        let target = EasyWindowVideoSizing.contentSizeByScalingDownToFit(
            CGSize(width: 1000, height: 104 + 500),
            topChromeHeight: 104,
            maximumContentSize: CGSize(width: 600, height: 104 + 300)
        )

        XCTAssertEqual(target.width, 600, accuracy: 0.001)
        XCTAssertEqual(target.height, 104 + 300, accuracy: 0.001)
    }

    func testPortraitWidthDrivenResizeUsesRealPhoneAspect() {
        let target = EasyWindowVideoSizing.targetContentSizeForResize(
            contentSize: CGSize(width: 300, height: 104 + 650),
            displayedPhoneSize: CGSize(width: 390, height: 844),
            topChromeHeight: 104,
            minimumContentWidth: 0,
            driver: .width
        )

        XCTAssertEqual(target.width, 300, accuracy: 0.001)
        XCTAssertEqual(target.height, 104 + (300 / (390.0 / 844.0)), accuracy: 0.001)
    }

    func testWidthDrivenResizeExpandsHeightWhenMinimumWidthForcesWiderVideo() {
        let target = EasyWindowVideoSizing.targetContentSizeForResize(
            contentSize: CGSize(width: 282, height: 104 + 612),
            displayedPhoneSize: CGSize(width: 390, height: 844),
            topChromeHeight: 104,
            minimumContentWidth: 300,
            driver: .width
        )

        XCTAssertEqual(target.width, 300, accuracy: 0.001)
        XCTAssertEqual(target.height, 104 + (300 / (390.0 / 844.0)), accuracy: 0.001)
    }

    func testLandscapeWidthDrivenResizeIsNotSquare() {
        let target = EasyWindowVideoSizing.targetContentSizeForResize(
            contentSize: CGSize(width: 650, height: 104 + 300),
            displayedPhoneSize: CGSize(width: 844, height: 390),
            topChromeHeight: 104,
            minimumContentWidth: 0,
            driver: .width
        )

        XCTAssertEqual(target.width, 650, accuracy: 0.001)
        XCTAssertEqual(target.height, 104 + (650 / (844.0 / 390.0)), accuracy: 0.001)
    }

    func testPhoneWindowCornerRadiusUsesShortEdgeAcrossRotation() {
        let portraitRadius = EasyMirroringPhoneSurfaceGeometry.cornerRadius(
            for: CGSize(width: 430, height: 932)
        )
        let landscapeRadius = EasyMirroringPhoneSurfaceGeometry.cornerRadius(
            for: CGSize(width: 932, height: 430)
        )

        XCTAssertEqual(portraitRadius, 55, accuracy: 0.001)
        XCTAssertEqual(landscapeRadius, 55, accuracy: 0.001)
    }

    func testPhoneWindowCornerRadiusRejectsInvalidGeometry() {
        XCTAssertEqual(
            EasyMirroringPhoneSurfaceGeometry.cornerRadius(for: CGSize(width: 0, height: 430)),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            EasyMirroringPhoneSurfaceGeometry.cornerRadius(for: CGSize(width: CGFloat.nan, height: 430)),
            0,
            accuracy: 0.001
        )
    }
}

final class InputSurfaceDiagnosticsTests: XCTestCase {
    func testIntStringHandlesNonFiniteCoordinatesWithoutCrashing() {
        XCTAssertEqual(InputSurfaceDiagnostics.intString(CGFloat.nan), "nan")
        XCTAssertEqual(InputSurfaceDiagnostics.intString(CGFloat.infinity), "+inf")
        XCTAssertEqual(InputSurfaceDiagnostics.intString(-CGFloat.infinity), "-inf")
    }

    func testRectValidationRejectsNonFiniteSurfaceGeometry() {
        XCTAssertFalse(
            InputSurfaceDiagnostics.isFinite(
                CGRect(x: CGFloat.nan, y: 0, width: 300, height: 650)
            )
        )
        XCTAssertTrue(
            InputSurfaceDiagnostics.isFinite(
                CGRect(x: 0, y: 0, width: 300, height: 650)
            )
        )
    }
}
