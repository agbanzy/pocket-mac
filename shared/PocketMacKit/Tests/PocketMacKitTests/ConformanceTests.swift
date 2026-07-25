import Foundation
import Testing
@testable import PocketMacKit

/// Binds this implementation to `shared/conformance/vectors.json`. The TypeScript (and future
/// Kotlin/C#) ports assert against the same file, so the vectors are a real contract rather than a
/// copy that can rot: change an opcode here without updating the file and this fails; change the
/// file without updating a port and that port fails.
@Suite("Wire protocol conformance vectors")
struct ConformanceTests {

    /// vectors.json lives at <repo>/shared/conformance/vectors.json; this file is at
    /// <repo>/shared/PocketMacKit/Tests/PocketMacKitTests/.
    static func loadVectors() throws -> [String: [String: Int]] {
        let here = URL(fileURLWithPath: #filePath)
        let vectorsURL = here
            .deletingLastPathComponent()   // …/PocketMacKitTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/PocketMacKit
            .deletingLastPathComponent()   // …/shared
            .appendingPathComponent("conformance/vectors.json")
        let data = try Data(contentsOf: vectorsURL)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let enums = root?["enums"] as? [String: [String: Int]]
        return try #require(enums)
    }

    @Test("ControlOpcode matches the canonical vectors")
    func controlOpcode() throws {
        let expected = try #require(Self.loadVectors()["ControlOpcode"])
        let actual: [String: Int] = [
            "hello": Int(ControlOpcode.hello.rawValue),
            "ack": Int(ControlOpcode.ack.rawValue),
            "error": Int(ControlOpcode.error.rawValue),
            "ping": Int(ControlOpcode.ping.rawValue),
            "pong": Int(ControlOpcode.pong.rawValue),
            "startVideo": Int(ControlOpcode.startVideo.rawValue),
            "stopVideo": Int(ControlOpcode.stopVideo.rawValue),
            "runTask": Int(ControlOpcode.runTask.rawValue),
            "taskEvent": Int(ControlOpcode.taskEvent.rawValue),
            "stopTask": Int(ControlOpcode.stopTask.rawValue),
            "pinResponse": Int(ControlOpcode.pinResponse.rawValue),
            "setProvider": Int(ControlOpcode.setProvider.rawValue),
            "getProviders": Int(ControlOpcode.getProviders.rawValue),
            "providerList": Int(ControlOpcode.providerList.rawValue),
            "getMemory": Int(ControlOpcode.getMemory.rawValue),
            "memoryList": Int(ControlOpcode.memoryList.rawValue),
            "forgetMemory": Int(ControlOpcode.forgetMemory.rawValue),
            "getHistory": Int(ControlOpcode.getHistory.rawValue),
            "historyList": Int(ControlOpcode.historyList.rawValue),
            "getSchedules": Int(ControlOpcode.getSchedules.rawValue),
            "scheduleList": Int(ControlOpcode.scheduleList.rawValue),
            "setSchedule": Int(ControlOpcode.setSchedule.rawValue),
            "removeSchedule": Int(ControlOpcode.removeSchedule.rawValue),
        ]
        #expect(actual == expected)
    }

    @Test("TaskEventKind matches the canonical vectors")
    func taskEventKind() throws {
        let expected = try #require(Self.loadVectors()["TaskEventKind"])
        let actual: [String: Int] = [
            "started": Int(TaskEventKind.started.rawValue),
            "thinking": Int(TaskEventKind.thinking.rawValue),
            "action": Int(TaskEventKind.action.rawValue),
            "needsPin": Int(TaskEventKind.needsPin.rawValue),
            "done": Int(TaskEventKind.done.rawValue),
            "error": Int(TaskEventKind.error.rawValue),
        ]
        #expect(actual == expected)
    }

    @Test("FrameDomain matches the canonical vectors")
    func frameDomain() throws {
        let expected = try #require(Self.loadVectors()["FrameDomain"])
        let actual = Dictionary(uniqueKeysWithValues: FrameDomain.allCases.map {
            (String(describing: $0), Int($0.rawValue))
        })
        #expect(actual == expected)
    }

    @Test("InputOpcode matches the canonical vectors")
    func inputOpcode() throws {
        let expected = try #require(Self.loadVectors()["InputOpcode"])
        let actual: [String: Int] = [
            "mouseMove": Int(InputOpcode.mouseMove.rawValue),
            "mouseDown": Int(InputOpcode.mouseDown.rawValue),
            "mouseUp": Int(InputOpcode.mouseUp.rawValue),
            "mouseClick": Int(InputOpcode.mouseClick.rawValue),
            "scroll": Int(InputOpcode.scroll.rawValue),
            "keyDown": Int(InputOpcode.keyDown.rawValue),
            "keyUp": Int(InputOpcode.keyUp.rawValue),
            "unicodeText": Int(InputOpcode.unicodeText.rawValue),
            "setModifiers": Int(InputOpcode.setModifiers.rawValue),
            "mouseMoveAbsolute": Int(InputOpcode.mouseMoveAbsolute.rawValue),
        ]
        #expect(actual == expected)
    }
}
