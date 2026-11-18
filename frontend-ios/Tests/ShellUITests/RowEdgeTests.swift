#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ShellUI

/// #511: on the iPhone Duo outer screen the system keeps a strip at the trailing edge (the status bar sits there), so
/// the library gets a trailing safe-area inset. The row of covers is sized for the width inside the safe area, but a
/// scroll view draws its content under the insets, so the third card showed in the strip, cut at the screen edge.
/// These tests render the upright library with such a strip and look at the pixels in it.
@MainActor
final class RowEdgeTests: XCTestCase {
    private let screen = CGSize(width: 440, height: 520)
    /// What is left inside the safe area (370 points) holds two whole covers, as on the outer screen.
    private let strip: CGFloat = 70

    private func games(_ count: Int) -> [GameDetail] {
        let titles = ["The Legend of Zelda: Tears of the Kingdom", "Hollow Knight: Silksong", "Hades II", "Celeste"]
        return (0..<count).map { GameDetail(game: GameTile(id: "0100\($0)", title: titles[$0 % titles.count])) }
    }

    /// The library rendered at the outer screen's size with a clear strip at the trailing edge, as a bitmap.
    private func render(_ count: Int) throws -> NSBitmapImageRep {
        let view = LibraryView(games: games(count))
            .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: strip) }
            .frame(width: screen.width, height: screen.height)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: screen)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: screen),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("row-edge-\(count).png"))
        }
        return rep
    }

    /// How many points in the strip, below the hero, differ from the page colour: a card drawn there shows up.
    private func drawnInStrip(_ rep: NSBitmapImageRep) -> Int {
        let scaleX = CGFloat(rep.pixelsWide) / screen.width, scaleY = CGFloat(rep.pixelsHigh) / screen.height
        let page = rep.colorAt(x: 4, y: Int(screen.height * 0.5 * scaleY))?.usingColorSpace(.sRGB)
            ?? NSColor(ShellPalette.background).usingColorSpace(.sRGB) ?? .black
        var count = 0
        // Below the hero (a little under half the screen) and above the bottom bar.
        for y in stride(from: screen.height * 0.45, to: screen.height * 0.8, by: 2) {
            for x in stride(from: screen.width - strip + 4, to: screen.width, by: 2) {
                guard let color = rep.colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?.usingColorSpace(.sRGB) else { continue }
                let distance = abs(color.redComponent - page.redComponent) + abs(color.greenComponent - page.greenComponent)
                    + abs(color.blueComponent - page.blueComponent)
                let black = color.redComponent + color.greenComponent + color.blueComponent
                if distance > 0.06 && black > 0.06 { count += 1 }
            }
        }
        return count
    }

    func testTwoGamesLeaveTheStripEmpty() throws {
        XCTAssertEqual(drawnInStrip(try render(2)), 0)
    }

    /// The bug: with a third game its card was drawn in the strip and cut at the screen edge.
    func testMoreThanTwoGamesDrawNoCardInTheStrip() throws {
        XCTAssertEqual(drawnInStrip(try render(4)), 0, "a card is drawn under the trailing inset and cut at the screen edge")
    }

    /// Regression test: in landscape mode with a 1:1 square game icon, the console shelf cards and Play button must
    /// remain docked near the bottom of the screen and never shift up to the top edge.
    func testLandscapeConsoleShelfSitsNearScreenBottomEvenWithSquareIcon() throws {
        let landscape = CGSize(width: 1024, height: 473)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.65, green: 0.12, blue: 0.18, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        let squareIcon = Artwork(id: "square-icon", image: try XCTUnwrap(ctx.makeImage()))

        let items = (0..<4).map { idx in
            GameDetail(game: GameTile(id: "0100\(idx)", title: "Game \(idx)", icon: squareIcon, state: .playable))
        }
        let insets = EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)
        let view = LibraryView(games: items, initialSelection: "01000")
            .safeAreaPadding(insets)
            .frame(width: landscape.width, height: landscape.height)
            .background(Color.black)
            .environment(\.colorScheme, .dark)

        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: landscape)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: landscape),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        // Find the selected card's bright white border in the lower half vs upper half (x > 130 skips the left nav rail)
        let scaleX = CGFloat(rep.pixelsWide) / landscape.width
        let scaleY = CGFloat(rep.pixelsHigh) / landscape.height
        var topHalfWhiteBorder = 0
        var bottomDockWhiteBorder = 0
        var maxCardY = 0
        for y in 0..<rep.pixelsHigh {
            for x in Int(130 * scaleX)..<Int(400 * scaleX) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.92 && c.greenComponent > 0.92 && c.blueComponent > 0.92 {
                    if CGFloat(y) < landscape.height * 0.45 * scaleY {
                        topHalfWhiteBorder += 1
                    } else if CGFloat(y) > landscape.height * 0.65 * scaleY {
                        bottomDockWhiteBorder += 1
                        maxCardY = max(maxCardY, y)
                    }
                }
            }
        }
        XCTAssertEqual(topHalfWhiteBorder, 0, "Selected game card border must never appear in the top half of the screen")
        XCTAssertGreaterThan(bottomDockWhiteBorder, 100, "Selected game card border must be rendered in the bottom dock")
        XCTAssertGreaterThan(CGFloat(maxCardY) / scaleY, landscape.height - insets.bottom - 20,
                             "Game cards must be docked near the bottom safe area of the screen")
    }
}
#endif
