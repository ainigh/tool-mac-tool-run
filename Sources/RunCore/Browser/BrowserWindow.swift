import Foundation

/// The app's own Chrome window, while there is one: its id, where it's put (side by side with
/// the person's, or behind it), and, side by side, the person's window it was set beside and where
/// that window was before, so it can be put back when the app's own is closed.
public actor BrowserWindow {
    public struct State: Sendable, Equatable {
        public var id: Int
        public var place: ChromePage.Place
        /// The person's window it was set beside, and where that window was before.
        public var user: Int?
        public var userBounds: ChromePage.Bounds?
    }

    public private(set) var state: State?

    public init() {}

    public func set(_ s: State?) { state = s }

    public func forget() { state = nil }
}
