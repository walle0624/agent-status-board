import Foundation
import Testing
@testable import AgentStatusBoard

private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.anthropic.com/v1/messages")!,
                    statusCode: status, httpVersion: nil, headerFields: headers)!
}

@Test func rejectedClaudeCredentialsRequireReauthorization() {
    for (code, expected) in [(401, ClaudeUsageError.invalidToken), (403, .permissionDenied)] {
        let result = UsageCollector.claudeUsageResponse(response(code))
        guard case .failure(let error) = result else { Issue.record("Rejected credentials produced usage"); continue }
        #expect(error == expected)
        #expect(error.invalidatesPreviousUsage)
    }
}

@Test func claudeQuotaHeadersAreReadableEvenWhenQuotaIsExhausted() {
    let headers = ["anthropic-ratelimit-unified-5h-utilization": "1",
                   "anthropic-ratelimit-unified-5h-reset": "2000000000",
                   "anthropic-ratelimit-unified-7d-utilization": "0.42",
                   "anthropic-ratelimit-unified-7d-reset": "2000100000"]
    let now = Date(timeIntervalSince1970: 1900000000)
    let result = UsageCollector.claudeUsageResponse(response(429, headers), now: now)
    guard case .success(let usage) = result else { Issue.record("Valid quota headers lost on 429"); return }
    #expect(usage.short?.usedPercent == 100)
    #expect(usage.long?.usedPercent == 42)
    #expect(usage.snapshotAt == now)
}

@Test func missingOrMalformedClaudeQuotaDoesNotBecomeZeroUsage() {
    for headers in [[:], ["anthropic-ratelimit-unified-5h-utilization": "nan",
                          "anthropic-ratelimit-unified-5h-reset": "2000000000"]] {
        let result = UsageCollector.claudeUsageResponse(response(200, headers))
        guard case .failure(let error) = result else { Issue.record("Missing usage became a balance"); continue }
        #expect(error == .missingWindows)
    }
    let limited = UsageCollector.claudeUsageResponse(response(429))
    guard case .failure(let error) = limited else { Issue.record("Missing rate-limit headers became usage"); return }
    #expect(error == .rateLimited)
    #expect(!error.invalidatesPreviousUsage)
}
