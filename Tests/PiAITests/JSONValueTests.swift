import Foundation
import Testing
@testable import PiAI

@Suite struct JSONValueTests {
    @Test func literalConstruction() {
        let value: JSONValue = [
            "name": "pi",
            "count": 3,
            "ratio": 1.5,
            "enabled": true,
            "missing": nil,
            "items": [1, 2, 3],
        ]
        #expect(value["name"] == .string("pi"))
        #expect(value["count"] == .int(3))
        #expect(value["ratio"] == .double(1.5))
        #expect(value["enabled"] == .bool(true))
        #expect(value["missing"].isNull)
        #expect(value["items"] == .array([.int(1), .int(2), .int(3)]))
    }

    @Test func numberFactoryPrefersIntegersForWholeValues() {
        #expect(JSONValue.number(3.0) == .int(3))
        #expect(JSONValue.number(3.5) == .double(3.5))
        #expect(JSONValue.number(Int.max) == .int(Int.max))
        #expect(JSONValue.number(.infinity) == .double(.infinity))
    }

    @Test func accessors() {
        let value: JSONValue = ["a": 1, "b": "x", "c": true, "d": 2.5, "e": nil, "f": [1]]
        #expect(value["a"].intValue == 1)
        #expect(value["a"].doubleValue == 1)
        #expect(value["b"].stringValue == "x")
        #expect(value["c"].boolValue == true)
        #expect(value["d"].doubleValue == 2.5)
        #expect(value["d"].intValue == nil)
        #expect(value["e"].isNull)
        #expect(value["f"].arrayValue == [.int(1)])
        #expect(value.objectValue != nil)
        #expect(value["f"].objectValue == nil)
    }

    @Test func subscriptMutation() {
        var object: JSONValue = .object([:])
        object["a"] = 1
        object["b"] = ["c": true]
        #expect(object["a"] == .int(1))
        #expect(object["b"]["c"] == .bool(true))

        var array: JSONValue = .array([.int(1), .int(2)])
        array[1] = .string("two")
        #expect(array == .array([.int(1), .string("two")]))
        // Out-of-bounds writes are ignored, reads return null.
        array[9] = .int(9)
        #expect(array.arrayValue?.count == 2)
        #expect(array[9].isNull)
    }

    @Test func roundTripAllCases() throws {
        let cases: [JSONValue] = [
            .null,
            .bool(false),
            .int(-42),
            .double(2.5),
            .string("héllo 🌍"),
            .array([.int(1), .null, .object(["k": .string("v")])]),
            .object(["nested": .array([.bool(true)])]),
        ]
        for value in cases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
            #expect(decoded == value)
        }
    }

    @Test func decodingFromJSONPreservesIntegerAndDouble() throws {
        let value = try TestSupport.jsonValue(fromJSON: #"{"i":1,"f":1.5,"e":1e3,"tiny":1e-3,"s":"x","b":true,"n":null}"#)
        #expect(value["i"] == .int(1))
        #expect(value["f"] == .double(1.5))
        #expect(value["e"] == .int(1000))
        #expect(value["tiny"] == .double(0.001))
        #expect(value["s"] == .string("x"))
        #expect(value["b"] == .bool(true))
        #expect(value["n"].isNull)
    }

    @Test func encodingFromEncodable() throws {
        struct Payload: Codable, Equatable {
            var name: String
            var count: Int
            var tags: [String]
        }
        let payload = Payload(name: "pi", count: 2, tags: ["a", "b"])
        let value = try JSONValue(encoding: payload)
        #expect(value["name"] == .string("pi"))
        #expect(value["count"] == .int(2))
        #expect(value["tags"] == .array([.string("a"), .string("b")]))

        let decoded = try value.decoded(as: Payload.self)
        #expect(decoded == payload)
    }

    @Test func decodingInvalidJSONThrows() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(JSONValue.self, from: Data("not json".utf8))
        }
    }
}
