import XCTest
@testable import ModelHubCore

final class ProviderModelCSVTests: XCTestCase {
    func testParsesQuotedCSVModelsPricesAndExactEndpoints() throws {
        let csv = """
        model,chat_endpoint,input_price_usd_per_million_tokens,output_price,request_price,price_source
        alpha,https://api.example.com/chat/alpha,0.25,1.5,0.01,Vendor pricing
        "beta,vision",https://api.example.com/chat/beta,0,2.25,,"Contract, 2026"
        """

        let result = try ProviderModelCSVImporter.parse(Data(csv.utf8))

        XCTAssertEqual(result.models, ["alpha", "beta,vision"])
        XCTAssertEqual(result.prices["alpha"]?.inputPerMillionTokensUSD, 0.25)
        XCTAssertEqual(result.prices["alpha"]?.perRequestUSD, 0.01)
        XCTAssertEqual(result.prices["beta,vision"]?.outputPerMillionTokensUSD, 2.25)
        XCTAssertEqual(result.prices["beta,vision"]?.source, "Contract, 2026")
        XCTAssertEqual(
            result.endpointURLs[ProviderEndpointRecord.key(for: .chat, model: "alpha")],
            "https://api.example.com/chat/alpha"
        )
    }

    func testSupportsChineseHeadersBOMCRLFAndCaseInsensitiveDeduplication() throws {
        let csv = "\u{FEFF}模型名称,输入价格,输出价格\r\nAlpha,1,2\r\nalpha,3,4\r\n"
        let result = try ProviderModelCSVImporter.parse(Data(csv.utf8))

        XCTAssertEqual(result.models, ["Alpha"])
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(result.prices["Alpha"]?.inputPerMillionTokensUSD, 1)
    }

    func testSupportsExcelSeparatorDirectiveAndCommonModelIDHeaders() throws {
        let csv = """
        sep=;
        模型 ID;输入单价;输出单价;聊天端点
        qwen-plus;0.8;2;https://example.com/v1/chat/completions
        """

        let result = try ProviderModelCSVImporter.parse(Data(csv.utf8))

        XCTAssertEqual(result.models, ["qwen-plus"])
        XCTAssertEqual(result.prices["qwen-plus"]?.inputPerMillionTokensUSD, 0.8)
        XCTAssertEqual(result.prices["qwen-plus"]?.outputPerMillionTokensUSD, 2)
        XCTAssertEqual(
            result.endpointURLs[
                ProviderEndpointRecord.key(for: .chat, model: "qwen-plus")
            ],
            "https://example.com/v1/chat/completions"
        )
    }

    func testSupportsUTF16CSVWithByteOrderMark() throws {
        let csv = "model_id,input_price_usd_per_1m_tokens\nalpha,0.25\n"
        var data = Data([0xFF, 0xFE])
        data.append(try XCTUnwrap(csv.data(using: .utf16LittleEndian)))

        let result = try ProviderModelCSVImporter.parse(data)

        XCTAssertEqual(result.models, ["alpha"])
        XCTAssertEqual(result.prices["alpha"]?.inputPerMillionTokensUSD, 0.25)
    }

    func testRejectsMissingModelHeaderMalformedPricesAndCredentialURLs() throws {
        XCTAssertThrowsError(
            try ProviderModelCSVImporter.parse(Data("name\nalpha".utf8))
        ) { error in
            XCTAssertEqual(error as? ProviderModelCSVError, .missingModelColumn)
        }
        XCTAssertThrowsError(
            try ProviderModelCSVImporter.parse(Data("model,input_price\nalpha,-1".utf8))
        ) { error in
            XCTAssertEqual(
                error as? ProviderModelCSVError,
                .invalidPrice(row: 2, column: "input_price")
            )
        }
        XCTAssertThrowsError(
            try ProviderModelCSVImporter.parse(
                Data("model,endpoint\nalpha,https://key:secret@example.com/chat".utf8)
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderModelCSVError,
                .invalidEndpoint(row: 2, column: "endpoint")
            )
        }
    }

    func testRejectsOversizedInputBeforeParsing() {
        let data = Data(repeating: 65, count: ProviderModelCSVImporter.maximumFileBytes + 1)
        XCTAssertThrowsError(try ProviderModelCSVImporter.parse(data)) { error in
            XCTAssertEqual(
                error as? ProviderModelCSVError,
                .fileTooLarge(maximumBytes: ProviderModelCSVImporter.maximumFileBytes)
            )
        }
    }

    func testParsesMaximumSupportedRowCountWithLinearBoundedInput() throws {
        var csv = "model,input_price,output_price\n"
        csv.reserveCapacity(500_000)
        for index in 0..<ProviderModelCSVImporter.maximumRows {
            csv += "model-\(index),0.1,0.2\n"
        }
        let data = Data(csv.utf8)
        XCTAssertLessThan(data.count, ProviderModelCSVImporter.maximumFileBytes)

        let started = ContinuousClock.now
        let result = try ProviderModelCSVImporter.parse(data)
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(result.models.count, ProviderModelCSVImporter.maximumRows)
        XCTAssertEqual(result.prices.count, ProviderModelCSVImporter.maximumRows)
        print("CSV_BASELINE rows=\(result.models.count) bytes=\(data.count) elapsed=\(elapsed)")
    }
}
