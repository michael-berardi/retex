import XCTest
@testable import RetexCore

/// Drives the MCP server over in-memory pipes so tools can be exercised
/// without spawning processes or touching real stdio.
enum MCPTestHarness {
    /// Sends newline-delimited requests, collects newline-delimited responses.
    static func run(vault: Vault, requests: [String], readOnly: Bool = false) throws -> [String] {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let collected = LockedBox(Data())

        let feeder = Thread {
            for request in requests {
                inputPipe.fileHandleForWriting.write(Data((request + "\n").utf8))
            }
            inputPipe.fileHandleForWriting.closeFile()
        }

        let reader = Thread {
            while true {
                let chunk = outputPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                collected.with { $0.append(chunk) }
            }
        }

        let server = MCPServer(
            vault: vault,
            readOnly: readOnly,
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting
        )

        feeder.start()
        reader.start()

        // run() blocks until stdin EOF (feeder closes the write end).
        try server.run()

        // Close the response write end so the reader sees EOF, then drain.
        outputPipe.fileHandleForWriting.closeFile()
        while !reader.isFinished {
            Thread.sleep(forTimeInterval: 0.01)
        }

        return collected.with { String(decoding: $0, as: UTF8.self) }
            .split(separator: "\n")
            .map(String.init)
    }
}
