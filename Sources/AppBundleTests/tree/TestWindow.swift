@testable import AppBundle
import AppKit
import Common

final class TestWindow: Window, CustomStringConvertible {
    private var _rect: Rect?
    var nativeWindowIdForTest: UInt32?
    override var nativeWindowId: UInt32? { nativeWindowIdForTest }
    var isMacosFullscreenForTest = false
    var onGetAxSize: (@MainActor () -> Void)?
    var onGetAxRect: (@MainActor () -> Void)?
    var rejectAxFrameChangesForTest = false
    /// Like a real app, the window refuses to be made smaller than this
    var appMinimumSizeForTest: CGSize?
    var setAxFrameCallCountForTest = 0

    @MainActor
    private init(_ id: OpaqueWindowId, _ parent: NonLeafTreeNodeObject, _ adaptiveWeight: CGFloat, _ rect: Rect?) {
        _rect = rect
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
    }

    @discardableResult
    @MainActor
    static func new(id: OpaqueWindowId, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat = 1, rect: Rect? = nil) -> TestWindow {
        let wi = TestWindow(id, parent, adaptiveWeight, rect)
        TestApp.shared._windows.append(wi)
        return wi
    }

    nonisolated var description: String { "TestWindow(\(windowId))" }

    @MainActor
    override func nativeFocus() {
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = self
    }

    override func closeAxWindow() {
        unbindFromParent()
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { description }

    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { // todo change to not Optional
        onGetAxRect?()
        onGetAxRect = nil
        return _rect
    }

    @MainActor override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        onGetAxSize?()
        onGetAxSize = nil
        return _rect.map { CGSize(width: $0.width, height: $0.height) }
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        setAxFrameCallCountForTest += 1
        if rejectAxFrameChangesForTest { return }
        let current = _rect ?? Rect(topLeftX: 0, topLeftY: 0, width: 0, height: 0)
        _rect = Rect(
            topLeftX: topLeft?.x ?? current.topLeftX,
            topLeftY: topLeft?.y ?? current.topLeftY,
            width: max(size?.width ?? current.width, appMinimumSizeForTest?.width ?? 0),
            height: max(size?.height ?? current.height, appMinimumSizeForTest?.height ?? 0),
        )
    }

    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { isMacosFullscreenForTest }

    override func setNativeFullscreen(_ value: Bool) {
        isMacosFullscreenForTest = value
    }
}

extension OpaqueWindowId: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) { self.init(value) }
}
