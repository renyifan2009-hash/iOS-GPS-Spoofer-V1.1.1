import XCTest
@testable import SpooferCore

/// `iosgpsspoof teleport @Name` and the menu look favorites up by what was typed.
final class FavoriteLookupTests: XCTestCase {
    private let library = LibraryData(favorites: [
        SavedPlace(name: "Home", point: GeoPoint(1, 1)),
        SavedPlace(name: "Homestead", point: GeoPoint(2, 2)),
        SavedPlace(name: "Work", point: GeoPoint(3, 3)),
        SavedPlace(name: "Gym", point: GeoPoint(4, 4)),
    ])

    func testABlankNameIsNotTheFirstFavorite() {
        // "teleport @" with nothing after the @ used to move the phone to the first favorite.
        for blank in ["", " ", "   ", "\t", "\n"] {
            XCTAssertNil(library.favorite(named: blank), "[\(blank)]")
            XCTAssertTrue(library.favorites(startingWith: blank).isEmpty)
        }
    }

    func testExactNamesWinOverLongerOnes() {
        XCTAssertEqual(library.favorite(named: "home")?.point, GeoPoint(1, 1))
        XCTAssertEqual(library.favorite(named: "  HOME  ")?.point, GeoPoint(1, 1))
        XCTAssertEqual(library.favorite(named: "Homestead")?.point, GeoPoint(2, 2))
    }

    func testAShortStartMustPointAtOneFavorite() {
        XCTAssertEqual(library.favorite(named: "wo")?.name, "Work")
        XCTAssertEqual(library.favorite(named: "G")?.name, "Gym")
        // "Hom" could be Home or Homestead: no guess.
        XCTAssertNil(library.favorite(named: "Hom"))
        XCTAssertEqual(library.favorites(startingWith: "hom").map(\.name), ["Home", "Homestead"])
        XCTAssertNil(library.favorite(named: "gym membership"))
    }
}
