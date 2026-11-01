@testable import AppBundle
import AppKit
import Common

final class TestWindow: Window, CustomStringConvertible {
    private var _rect: Rect?
    var nativeWindowIdForTest: UInt32?
    override var nativeWindowId: UInt32? { nativeWindowIdForTest }
    var isMacosFullscreenForTest = false
    var isMacosMinimizedForTest = false
    var onGetAxSize: (@MainActor () -> Void)?
    var onGetAxRect: (@MainActor () -> Void)?
    var onSetAxFrame: (@MainActor () -> Void)?
    var rejectAxFrameChangesForTest = false
    /// Like a real app, the window refuses to be made smaller than this
    var appMinimumSizeForTest: CGSize?
    var setAxFrameCallCountForTest = 0

    @MainActor
    private init(_ id: OpaqueWindowId, _ parent: NonLeafTreeNodeObject, _ adaptiveWeight: CGFloat, _ rect: Rect?, _ app: TestApp) {
        _rect = rect
        super.init(id: id, app, lastFloatingSize: nil, parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
    }

    @discardableResult
    @MainActor
    static func new(id: OpaqueWindowId, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat = 1, rect: Rect? = nil, app: TestApp = .shared) -> TestWindow {
        let wi = TestWindow(id, parent, adaptiveWeight, rect, app)
        app._windows.append(wi)
        return wi
    }

    nonisolated var description: String { "TestWindow(\(windowId))" }

    @MainActor
    override func nativeFocus() {
        appForTests = app
        (app as! TestApp).focusedWindow = self
    }

    override func closeAxWindow() {
        unbindFromParent()
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { description }

    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { // todo change to not Optional
        // A queued AX reply can describe the native window that existed before a remap during the read.
        let reply = _rect
        onGetAxRect?()
        onGetAxRect = nil
        return reply
    }

    @MainActor override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        let reply = _rect.map { CGSize(width: $0.width, height: $0.height) }
        onGetAxSize?()
        onGetAxSize = nil
        return reply
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        let callback = onSetAxFrame
        onSetAxFrame = nil
        MainActor.assumeIsolated { callback?() }
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
    override func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { isMacosMinimizedForTest }

    override func setNativeFullscreen(_ value: Bool) {
        isMacosFullscreenForTest = value
    }
}

extension OpaqueWindowId: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) { self.init(value) }
}
