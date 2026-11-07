import Foundation
import Testing
@testable import SmartTerminalCore

@Suite struct CommandProposalTests {
    @Test func plainCommandsCanBeTyped() {
        #expect(CommandProposal.problem(with: "npm publish") == nil)
        #expect(CommandProposal.problem(with: "cd ~/x && gcloud auth login --no-launch-browser | tee \"a b\"") == nil)
        #expect(CommandProposal.problem(with: "echo 'héllo 🌍'") == nil)
    }

    @Test func nothingThatCouldRunOrDisguiseItself() {
        for bad in ["ls\nrm -rf ~", "ls\r", "ls\tx", "ls \u{1B}[A", "ls \u{7F}", "ls \u{9B}", "echo \u{202E}txt.exe", "   ", ""] {
            #expect(CommandProposal.problem(with: bad) != nil, "\(bad.debugDescription)")
        }
        #expect(CommandProposal.problem(with: String(repeating: "a", count: CommandProposal.maxLength + 1)) != nil)
    }

    @Test func outcomesParse() {
        #expect(CommandProposal.parseOutcome("0\nnpm publish --otp 123456\n") == .init(exitCode: 0, command: "npm publish --otp 123456"))
        #expect(CommandProposal.parseOutcome("130\n") == .init(exitCode: 130, command: ""))
        #expect(CommandProposal.parseOutcome("x\nls") == nil)
    }

    @Test func outputStartsAfterTheCommandLine() {
        let screen = ["banner", "❯ ls", "old", "❯ echo hi && false", "hi", "", ""]
        #expect(CommandProposal.output(screen, command: "echo hi && false") == "hi")
        #expect(CommandProposal.output(["a", "b"], command: "zzz") == "a\nb")
        // Wrapped at the pane's edge:
        #expect(CommandProposal.output(["❯ echo hello from proposal && fa", "lse", "hello from proposal"],
                                       command: "echo hello from proposal && false") == "lse\nhello from proposal")
    }

    @Test func tailDropsTrailingBlankLines() {
        #expect(CommandProposal.tail(["a  ", "b", "", "  "], limit: 1) == "b")
        #expect(CommandProposal.tail(["a", "b", "c"], limit: 2) == "b\nc")
    }
}
