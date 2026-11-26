import CryptoKit
import Foundation
import SnowSweepCore

// 样本导出器命令行入口。
//
// 用法：
//   SampleExport --fixture --out <目录>
//   SampleExport --case <规则缺失报告.json> --out <目录> [--rule-book <rules.json>]
//
// 只做三件事：读输入、脱敏、写包（可选打 zip）。不扫描、不删除、不联网。

struct Options {
    var fixture = false
    var casePath: String?
    var outPath = FileManager.default.currentDirectoryPath
    var rulePath: String?
    var category = "unknown"
    var zip = true
}

enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknown(String)
    case ruleBookRequired

    var description: String {
        switch self {
        case .missingValue(let flag): return "参数 \(flag) 缺少取值"
        case .unknown(let flag): return "未知参数：\(flag)"
        case .ruleBookRequired: return "找不到 Rules/rules.json，请用 --rule-book 指定"
        }
    }
}

let usage = """
用法：
  SampleExport --fixture --out <目录>
      生成 3 份合成夹具样本（只用 example 假路径，不读本机数据）
  SampleExport --case <报告.json> --out <目录> [--rule-book <rules.json>] [--category <分类>]
      把应用导出的规则缺失报告转成脱敏样本
  SampleExport --fixture --out <目录> --no-zip
      只写目录，不打 zip
"""

func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 1
    while index < arguments.count {
        let flag = arguments[index]
        switch flag {
        case "--fixture":
            options.fixture = true
            index += 1
        case "--case", "--out", "--rule-book", "--category":
            guard index + 1 < arguments.count else { throw CLIError.missingValue(flag) }
            let value = arguments[index + 1]
            switch flag {
            case "--case": options.casePath = value
            case "--out": options.outPath = value
            case "--rule-book": options.rulePath = value
            default: options.category = value
            }
            index += 2
        case "--no-zip":
            options.zip = false
            index += 1
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            throw CLIError.unknown(flag)
        }
    }
    return options
}

// MARK: - 规则库

struct RuleIdentity {
    let version: String
    let sha256: String
}

func ruleIdentity(explicitPath: String?) throws -> RuleIdentity {
    let url: URL
    if let explicitPath {
        url = URL(fileURLWithPath: explicitPath)
    } else {
        // 从可执行文件位置逐级向上找仓库根的 Rules/rules.json，兼容 swift run 与直接调 .build 产物。
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var found: URL?
        for _ in 0..<8 {
            directory.deleteLastPathComponent()
            let candidate = directory.appendingPathComponent("Rules/rules.json")
            if FileManager.default.fileExists(atPath: candidate.path) { found = candidate; break }
        }
        guard let found else { throw CLIError.ruleBookRequired }
        url = found
    }
    let data = try Data(contentsOf: url)
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let version = (object?["version"] as? String) ?? "unknown"
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return RuleIdentity(version: version, sha256: sha)
}

// MARK: - 合成夹具

struct FixtureCase {
    let category: String
    let query: String
    let paths: [String]
    let fileCount: Int
    let bytes: Int64
    let coverage: Double
}

let fixtureCases: [FixtureCase] = [
    FixtureCase(
        category: "caches",
        query: "清理某个应用更新留下的缓存",
        paths: [
            "/Users/example/Library/Caches/com.example.editor/20261101T091500Z-3f2a9c",
            "/Users/example/Library/Caches/com.example.editor/20261101T091500Z-3f2a9c/chunk-0001.tmp"
        ],
        fileCount: 240,
        bytes: 734_003_200,
        coverage: 0.87
    ),
    FixtureCase(
        category: "containers",
        query: "某个聊天工具占了很大空间",
        paths: [
            "/Users/example/Library/Containers/com.example.chat/Data/Library/Caches/9d41ab77c0de4f88",
            "/Users/example/Library/Containers/com.example.chat/Data/Library/Application Support/com.example.chat/accounts/1f2e3d4c"
        ],
        fileCount: 1_180,
        bytes: 4_700_000_000,
        coverage: 0.62
    ),
    FixtureCase(
        category: "documents",
        query: "桌面上的导出文件能不能一起清掉",
        paths: [
            "/Users/example/Documents/项目资料/最终版-2026.xlsx",
            "/Users/example/Desktop/导出/导出-20261101.csv"
        ],
        fileCount: 12,
        bytes: 88_000_000,
        coverage: 0.35
    )
]

func fixtureSamples(rules: RuleIdentity) -> [XueSample] {
    let redactor = SampleRedactor(home: "/Users/example")
    return fixtureCases.map { item in
        let context = SampleContext(
            category: item.category,
            query: item.query,
            coverage: item.coverage,
            fileCount: item.fileCount,
            bytes: item.bytes,
            ruleBookVersion: rules.version,
            ruleBookSHA256: rules.sha256,
            observedPaths: item.paths,
            result: "unknown",
            evidence: ["合成夹具：用于验证导出器行为，不含真实用户数据。"]
        )
        return SampleExporter.sample(from: context, redactor: redactor)
    }
}

// MARK: - 打包

func zipDirectory(_ directory: URL) throws -> URL {
    let zipURL = directory.deletingLastPathComponent()
        .appendingPathComponent(directory.lastPathComponent + ".zip")
    try? FileManager.default.removeItem(at: zipURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", directory.path, zipURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CLIError.unknown("ditto 打包失败，退出码 \(process.terminationStatus)")
    }
    return zipURL
}

// MARK: - 主流程

func run() throws {
    let options = try parse(CommandLine.arguments)
    guard options.fixture || options.casePath != nil else {
        print(usage)
        exit(2)
    }

    let outURL = URL(fileURLWithPath: options.outPath).standardizedFileURL
    try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
    let rules = try ruleIdentity(explicitPath: options.rulePath)

    var produced: [URL] = []

    if options.fixture {
        for sample in fixtureSamples(rules: rules) {
            let directory = outURL.appendingPathComponent("sample-\(sample.intent.category)-\(sample.sampleId.prefix(8))")
            try SampleExporter.write(sample, to: directory)
            produced.append(directory)
        }
    }

    if let casePath = options.casePath {
        let data = try Data(contentsOf: URL(fileURLWithPath: casePath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let unknownCase = try decoder.decode(UnknownCase.self, from: data)
        let sample = SampleExporter.sample(
            from: unknownCase,
            ruleBookVersion: rules.version,
            ruleBookSHA256: rules.sha256,
            category: options.category
        )
        let directory = outURL.appendingPathComponent("sample-case-\(sample.sampleId.prefix(8))")
        try SampleExporter.write(sample, to: directory)
        produced.append(directory)
    }

    for directory in produced {
        print("已写出：\(directory.path)")
        if options.zip {
            let zip = try zipDirectory(directory)
            print("已打包：\(zip.path)")
        }
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("导出失败：\(error)\n".utf8))
    exit(1)
}
