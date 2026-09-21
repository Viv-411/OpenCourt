import Foundation
import Testing
@testable import OpenCourtKit

// Real coordinates of the two pilot parks, about 1.7 km apart.
private let rylko = Coordinate(latitude: 42.1683, longitude: -87.9681)
private let drazner = Coordinate(latitude: 42.159, longitude: -87.959)

private func site(_ id: String, _ coordinate: Coordinate?) -> Site {
    Site(id: id, name: id, latitude: coordinate?.latitude, longitude: coordinate?.longitude,
         courtCount: 2)
}

@Suite struct NearestCourts {
    @Test func measuresDistanceBetweenParks() {
        let meters = Nearby.meters(from: rylko, to: drazner)
        #expect(abs(meters - 1_350) < 150)  // ~1.35 km, checked against Apple Maps
    }

    @Test func distanceToItselfIsZero() {
        #expect(Nearby.meters(from: rylko, to: rylko) == 0)
    }

    @Test func sortsClosestFirst() {
        let far = site("far", Coordinate(latitude: 41.8781, longitude: -87.6298))  // Chicago
        let sites = [far, site("drazner", drazner), site("rylko", rylko)]
        let order = Nearby.sorted(sites, from: rylko).map(\.id)
        #expect(order == ["rylko", "drazner", "far"])
    }

    @Test func sitesWithoutCoordinatesGoLast() {
        let sites = [site("unplaced", nil), site("drazner", drazner)]
        #expect(Nearby.sorted(sites, from: rylko).map(\.id) == ["drazner", "unplaced"])
    }

    @Test func withoutALocationNothingIsReordered() {
        let sites = [site("b", drazner), site("a", rylko)]
        #expect(Nearby.sorted(sites, from: nil).map(\.id) == ["b", "a"])
    }

    @Test func distanceTextUsesLocalUnits() {
        let miles = Nearby.text(meters: 1_609, locale: Locale(identifier: "en_US"))
        #expect(miles.contains("mi"))
        let km = Nearby.text(meters: 1_609, locale: Locale(identifier: "de_DE"))
        #expect(km.contains("km"))
    }

    @Test func aSiteKnowsHowFarAwayItIs() {
        let park = site("drazner", drazner)
        #expect(park.distanceText(from: rylko, locale: Locale(identifier: "en_US")) != nil)
        #expect(park.distanceText(from: nil) == nil)
        #expect(site("unplaced", nil).distanceText(from: rylko) == nil)
    }
}

@Suite struct DistanceWording {
    private let us = Locale(identifier: "en_US")

    /// The space between a number and its unit is non-breaking, so they never wrap apart.
    private func plain(_ meters: Double, _ locale: Locale) -> String {
        Nearby.text(meters: meters, locale: locale)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test func closeByReadsInFeet() {
        #expect(plain(50, us) == "164 ft")
    }

    @Test func aWalkReadsInMiles() {
        #expect(plain(411, us) == "0.3 mi")
        #expect(plain(1_609, us) == "1.0 mi")
    }

    @Test func farAwayDropsTheDecimal() {
        #expect(plain(40_000, us) == "25 mi")
    }

    @Test func theUnitNeverWrapsOntoItsOwnLine() {
        #expect(Nearby.text(meters: 411, locale: us).contains("\u{00A0}"))
        #expect(!Nearby.text(meters: 411, locale: us).contains(" "))
    }

    @Test func metricLocalesGetKilometres() {
        #expect(Nearby.text(meters: 1_609, locale: Locale(identifier: "de_DE")).contains("km"))
    }
}
