import Foundation
import Testing
@testable import SnowSweepCore

private func makeData(_ json: String) -> Data { Data(json.utf8) }

private let validRule = """
{
  "version": "0.2.0",
  "protectedPaths": ["/tmp/**"],
  "rules": [
    {"id":"sample-rule","risk":"safe","name":"测试规则","pathPattern":"/tmp/sample/**",
     "reason":"测试用","needConfirm":false}
  ]
}
"""

@Test func validRuleBookPasses() {
    #expect(RuleBookValidator.validate(jsonData: makeData(validRule)).isEmpty)
}

@Test func uppercaseRiskIsRejected() {
    let json = validRule.replacingOccurrences(of: "\"risk\":\"safe\"", with: "\"risk\":\"Safe\"")
    let issues = RuleBookValidator.validate(jsonData: makeData(json))
    #expect(issues.contains { $0.path.hasSuffix(".risk") && $0.severity == .error })
    #expect(throws: (any Error).self) {
        try RuleBookValidator.assertValid(jsonData: makeData(json))
    }
}

@Test func unknownFieldIsRejected() {
    let json = validRule.replacingOccurrences(of: "\"needConfirm\":false", with: "\"needConfirm\":false,\"risks\":\"safe\"")
    let issues = RuleBookValidator.validate(jsonData: makeData(json))
    #expect(issues.contains { $0.path.hasSuffix(".risks") && $0.severity == .error })
}

@Test func duplicateRuleIDIsRejected() {
    let json = """
    {"version":"0.2.0","protectedPaths":["/tmp/**"],"rules":[
      {"id":"same","risk":"safe","name":"A","pathPattern":"/tmp/a/**","reason":"a","needConfirm":false},
      {"id":"same","risk":"review","name":"B","pathPattern":"/tmp/b/**","reason":"b","needConfirm":false}
    ]}
    """
    let issues = RuleBookValidator.validate(jsonData: makeData(json))
    #expect(issues.contains { $0.message.contains("重复的规则 id") })
}

@Test func missingRequiredFieldIsRejected() {
    let json = validRule.replacingOccurrences(of: ",\"needConfirm\":false", with: "")
    let issues = RuleBookValidator.validate(jsonData: makeData(json))
    #expect(issues.contains { $0.path.hasSuffix(".needConfirm") && $0.severity == .error })
}

@Test func invalidRiskAndRebuildCostAreRejected() {
    let json = validRule
        .replacingOccurrences(of: "\"risk\":\"safe\"", with: "\"risk\":\"dangerous\"")
        .replacingOccurrences(of: "\"name\":\"测试规则\"", with: "\"name\":\"测试规则\",\"rebuildCost\":\"medium\"")
    let issues = RuleBookValidator.validate(jsonData: makeData(json))
    #expect(issues.contains { $0.path.hasSuffix(".risk") })
    #expect(issues.contains { $0.path.hasSuffix(".rebuildCost") })
}

@Test func relativePathPatternIsRejected() {
    let json = validRule.replacingOccurrences(of: "\"/tmp/sample/**\"", with: "\"tmp/sample/**\"")
    let issues = RuleBookValidator.validate(jsonData: makeData(json))
    #expect(issues.contains { $0.message.contains("必须以 / 或 ~/ 开头") })
}

@Test func malformedJSONIsRejected() {
    let issues = RuleBookValidator.validate(jsonData: makeData("{not json"))
    #expect(issues.count == 1)
    #expect(issues.first?.severity == .error)
}
