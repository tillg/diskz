/// The folders visited in the browser, with back and forward as in Finder.
public struct NavigationHistory: Sendable, Equatable {
    public private(set) var current: String
    private var back: [String] = []
    private var forward: [String] = []

    public init(start: String) {
        current = start
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Goes to a folder by choice (double-click, breadcrumb); this ends the forward trail.
    public mutating func open(_ path: String) {
        guard path != current else { return }
        back.append(current)
        forward.removeAll()
        current = path
    }

    public mutating func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(current)
        current = previous
    }

    public mutating func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(current)
        current = next
    }
}
