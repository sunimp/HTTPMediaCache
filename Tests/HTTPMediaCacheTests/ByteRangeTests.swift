//
//  ByteRangeTests.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

@testable import HTTPMediaCache
import XCTest

final class ByteRangeTests: XCTestCase {
    func testParsesClosedRangeHeader() throws {
        let range = try XCTUnwrap(ByteRange(requestHeader: "bytes=10-19"))
        XCTAssertEqual(range, ByteRange(start: 10, end: 19))
        XCTAssertEqual(range.length, 10)
        XCTAssertEqual(range.requestHeaderValue, "bytes=10-19")
    }

    func testParsesOpenEndedRangeHeader() throws {
        let range = try XCTUnwrap(ByteRange(requestHeader: "bytes=10-"))
        XCTAssertEqual(range, ByteRange(start: 10, end: nil))
        XCTAssertNil(range.length)
    }

    func testParsesSuffixRangeHeader() throws {
        let range = try XCTUnwrap(ByteRange(requestHeader: "bytes=-500"))
        XCTAssertEqual(range, ByteRange(start: ByteRange.notFound, end: 500))
        XCTAssertEqual(range.requestHeaderValue, "bytes=-500")
    }

    func testNormalizedKeepsSuffixRange() {
        let range = ByteRange(start: ByteRange.notFound, end: 500)

        XCTAssertEqual(range.normalized(totalLength: 1000), range)
    }

    func testNormalizedCapsOpenEndedRange() {
        let range = ByteRange(start: 10, end: nil)

        XCTAssertEqual(range.normalized(totalLength: 20), ByteRange(start: 10, end: 19))
    }

    func testRejectsRangeHeadersInvalidInputs() {
        XCTAssertNil(ByteRange(requestHeader: "Bytes=10-19"))
        XCTAssertNil(ByteRange(requestHeader: " bytes=10-19"))
        XCTAssertNil(ByteRange(requestHeader: "bytes=10-19 "))
    }
}
