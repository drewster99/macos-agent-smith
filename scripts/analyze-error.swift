#!/usr/bin/env swift

import Foundation
import FoundationModels

@Generable
enum APIErrorMessageTarget: CustomStringConvertible {
    case user
    case developer

    var description: String {
        switch self {
        case .user: "user"
        case .developer: "developer"
        }
    }
}

var testErrors: [String] = [
    """
429 Too many requests: { "error": "rate_limit_exceeded", "message": "You have exceeded the rate limit of 100 requests per minute", "retry_after": 60 }
""",
    """
HTTP 400 from https://api.anthropic.com/v1/messages body={"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."},"request_id":"req_011CZjHLE9dMS8Zzh8nBjMnE"}
""",
    """
ViewBridge to RemoteViewService Terminated: Error Domain=com.apple.ViewBridge Code=18 "(null)" UserInfo={com.apple.ViewBridge.error.hint=this process disconnected remote view controller -- benign unless unexpected, com.apple.ViewBridge.error.description=NSViewBridgeErrorCanceled}
""",
    """
precondition failure: unable to load binary archive for shader library: /System/Library/PrivateFrameworks/IconRendering.framework/Resources/binary.metallib, The file file:///System/Library/PrivateFrameworks/IconRendering.framework/Resources/binary.metallib has an invalid format.
"""
    ]

@Generable
struct APIErrorAnalysis {
    @Guide(description: "A clear, human-readable explanation of what went wrong")
    let message: String
    @Guide(description: "Determine who this message is best shown to (user or developer)")
    let messageTarget: APIErrorMessageTarget
    @Guide(description: "Set to true if waiting a few minutes will likely resolve this issue")
    let isTransient: Bool
}

for error in testErrors {
    await check(error)
}

func check(_ error: String) async {
    let now = Date()
    defer {
        let elapsed = Date().timeIntervalSince(now)
        print("*** Completed in \(elapsed) seconds")
    }
    let session = LanguageModelSession(instructions: """
    You are an API error analyst. Given a raw API error response, extract the key \
    details into a structured format. Be concise and precise.
    """)

    do {
        let result = try await session.respond(
            to: "Analyze this API error and extract a human readable explanation of what went wrong:\n\(error)",
            generating: APIErrorAnalysis.self
        )

        let analysis = result.content

        print("INPUT:\n\(error)\n")
        print("Target: \(analysis.messageTarget)")
        print("Message: \(analysis.message)")
        print("Is transient?: \(analysis.isTransient)")
        print("---------------------------------------------------------")
    } catch {
        FileHandle.standardError.write(Data("Failed to analyze error: \(error.localizedDescription)\n".utf8))
//        exit(1)
    }
}
