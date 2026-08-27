import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Pi model catalog")
struct PiModelCatalogTests {
  @Test("decoder accepts canonical Pi output and sorts deterministically")
  func decodesCatalog() throws {
    let data = Data(
      """
      {"schemaVersion":1,"models":[{"provider":"openai-codex","id":"gpt-z","name":"GPT Z","reasoning":true,"input":["text","image"],"contextWindow":200000,"maxTokens":64000,"thinkingLevels":["off","minimal","low","medium","high","xhigh"]},{"provider":"anthropic","id":"claude-a","name":"Claude A","reasoning":false,"input":["text"],"contextWindow":100000,"maxTokens":8192,"thinkingLevels":["off"]}]}
      """.utf8)

    let catalog = try PiModelCatalogDecoder.decode(data)

    #expect(catalog.models.map(\.selectionID) == ["anthropic/claude-a", "openai-codex/gpt-z"])
    #expect(catalog.models[0].thinkingLevels == [.off])
    #expect(catalog.models[1].thinkingLevels.last == .xhigh)

    let noOff = Data(
      """
      {"schemaVersion":1,"models":[{"provider":"anthropic","id":"fable","name":"Fable","reasoning":true,"input":["text"],"contextWindow":1000000,"maxTokens":128000,"thinkingLevels":["minimal","low","medium","high","xhigh","max"]}]}
      """.utf8)
    #expect(try PiModelCatalogDecoder.decode(noOff).models[0].thinkingLevels.first == .minimal)
  }

  @Test("decoder rejects duplicates, unsupported levels, extra fields, and oversized output")
  func rejectsInvalidCatalogs() {
    let duplicate = Data(
      """
      {"schemaVersion":1,"models":[{"provider":"a","id":"m","name":"One","reasoning":false,"input":["text"],"contextWindow":1,"maxTokens":1,"thinkingLevels":["off"]},{"provider":"a","id":"m","name":"Two","reasoning":false,"input":["text"],"contextWindow":1,"maxTokens":1,"thinkingLevels":["off"]}]}
      """.utf8)
    let unsupported = Data(
      """
      {"schemaVersion":1,"models":[{"provider":"a","id":"m","name":"One","reasoning":false,"input":["text"],"contextWindow":1,"maxTokens":1,"thinkingLevels":["off","high"]}]}
      """.utf8)
    let extra = Data(
      """
      {"schemaVersion":1,"models":[],"credential":"secret"}
      """.utf8)
    let oversized = Data(repeating: 0x20, count: PiModelCatalogDecoder.maximumOutputBytes + 1)

    #expect(throws: PiModelCatalogError.invalidOutput) {
      try PiModelCatalogDecoder.decode(duplicate)
    }
    #expect(throws: PiModelCatalogError.invalidOutput) {
      try PiModelCatalogDecoder.decode(unsupported)
    }
    #expect(throws: PiModelCatalogError.invalidOutput) {
      try PiModelCatalogDecoder.decode(extra)
    }
    #expect(throws: PiModelCatalogError.invalidOutput) {
      try PiModelCatalogDecoder.decode(oversized)
    }
  }
}
