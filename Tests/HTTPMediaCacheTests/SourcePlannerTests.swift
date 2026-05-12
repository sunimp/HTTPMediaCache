//
//  SourcePlannerTests.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

@testable import HTTPMediaCache
import XCTest

final class SourcePlannerTests: XCTestCase {
    func testSplitsRequestIntoFileAndNetworkSources() {
        let planner = SourcePlanner()
        let plan = planner.plan(
            request: ByteRange(start: 0, end: 999),
            cachedZones: [
                ByteRange(start: 200, end: 499),
                ByteRange(start: 700, end: 799),
            ]
        )

        XCTAssertEqual(plan, [
            .network(ByteRange(start: 0, end: 199)),
            .file(ByteRange(start: 200, end: 499)),
            .network(ByteRange(start: 500, end: 699)),
            .file(ByteRange(start: 700, end: 799)),
            .network(ByteRange(start: 800, end: 999)),
        ])
    }

    func testKeepsOverlappingAndAdjacentFileSourcesDiscrete() {
        let planner = SourcePlanner()
        let plan = planner.plan(
            request: ByteRange(start: 0, end: 299),
            cachedZones: [
                ByteRange(start: 100, end: 199),
                ByteRange(start: 0, end: 99),
                ByteRange(start: 150, end: 249),
            ]
        )

        XCTAssertEqual(plan, [
            .file(ByteRange(start: 0, end: 99)),
            .file(ByteRange(start: 100, end: 199)),
            .file(ByteRange(start: 200, end: 249)),
            .network(ByteRange(start: 250, end: 299)),
        ])
    }

    func testKeepsAdjacentCachedZonesDiscreteWhenTheyReachRequestEnd() {
        let planner = SourcePlanner()
        let plan = planner.plan(
            request: ByteRange(start: 0, end: 199),
            cachedZones: [
                ByteRange(start: 0, end: 99),
                ByteRange(start: 100, end: 199),
            ]
        )

        XCTAssertEqual(plan, [
            .file(ByteRange(start: 0, end: 99)),
            .file(ByteRange(start: 100, end: 199)),
        ])
    }

    func testInvalidClosedRequestReturnsEmptyPlan() {
        let planner = SourcePlanner()
        let plan = planner.plan(
            request: ByteRange(start: 10, end: 9),
            cachedZones: [ByteRange(start: 0, end: 20)]
        )

        XCTAssertEqual(plan, [])
    }

    func testOpenEndedRequestReturnsNetworkSegment() {
        let planner = SourcePlanner()
        let request = ByteRange(start: 10, end: nil)
        let plan = planner.plan(
            request: request,
            cachedZones: [ByteRange(start: 10, end: 20)]
        )

        XCTAssertEqual(plan, [.network(request)])
    }
}
