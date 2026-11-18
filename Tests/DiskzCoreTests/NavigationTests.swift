import Testing
@testable import DiskzCore

/// Back and forward in the folder browser, as in Finder.
@Suite struct NavigationTests {
    @Test func backAndForwardRetraceTheVisitedFolders() {
        var nav = NavigationHistory(start: "/")
        #expect(!nav.canGoBack && !nav.canGoForward)

        nav.open("/a")
        nav.open("/a/b")
        #expect(nav.current == "/a/b")
        #expect(nav.canGoBack && !nav.canGoForward)

        nav.goBack()
        #expect(nav.current == "/a")
        nav.goBack()
        #expect(nav.current == "/")
        #expect(!nav.canGoBack && nav.canGoForward)

        nav.goForward()
        nav.goForward()
        #expect(nav.current == "/a/b")
        #expect(!nav.canGoForward)
    }

    @Test func openingAFolderDropsTheForwardTrail() {
        var nav = NavigationHistory(start: "/")
        nav.open("/a")
        nav.goBack()
        nav.open("/c")
        #expect(nav.current == "/c")
        #expect(!nav.canGoForward)
        nav.goBack()
        #expect(nav.current == "/")
    }

    @Test func reopeningTheCurrentFolderAddsNoStep() {
        var nav = NavigationHistory(start: "/")
        nav.open("/")
        #expect(!nav.canGoBack)
    }

    @Test func goingBackAtTheStartDoesNothing() {
        var nav = NavigationHistory(start: "/")
        nav.goBack()
        nav.goForward()
        #expect(nav.current == "/")
    }
}
