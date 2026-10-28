import Testing
@testable import SmartTerminalCore

@Suite struct GitStatusTests {
    @Test func parsesBranchUpstreamAndFiles() {
        let out = """
        # branch.oid 1f5f114a9c0e2b6d8e7f3a1b2c4d5e6f7a8b9c0d
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 aaa bbb CHANGELOG.md
        1 M. N... 100644 100644 100644 aaa bbb VERSION
        2 R. N... 100644 100644 100644 aaa bbb R100 new.swift\told.swift
        u UU N... 100644 100644 100644 100644 a b c conflict.swift
        ? notes.md
        ? scratch/
        """
        let s = GitStatus.parse(porcelainV2: out)
        #expect(s.branch == "main")
        #expect(s.commit == "1f5f114")
        #expect(s.hasUpstream)
        #expect(s.ahead == 2 && s.behind == 1)
        #expect(s.changedFiles == 4)
        #expect(s.untrackedFiles == 2)
        #expect(!s.isClean)
    }

    @Test func detachedAndFreshRepos() {
        let detached = GitStatus.parse(porcelainV2: "# branch.oid abcdef1234\n# branch.head (detached)\n")
        #expect(detached.branch == nil)
        #expect(detached.commit == "abcdef1")
        #expect(!detached.hasUpstream)
        #expect(detached.isClean)

        let fresh = GitStatus.parse(porcelainV2: "# branch.oid (initial)\n# branch.head main\n? a.txt\n")
        #expect(fresh.commit == nil)
        #expect(fresh.branch == "main")
        #expect(fresh.untrackedFiles == 1)
    }

    @Test func parsesShortstat() {
        #expect(GitStatus.parse(shortstat: " 3 files changed, 12 insertions(+), 4 deletions(-)\n") == (12, 4))
        #expect(GitStatus.parse(shortstat: " 1 file changed, 1 insertion(+)\n") == (1, 0))
        #expect(GitStatus.parse(shortstat: " 1 file changed, 7 deletions(-)\n") == (0, 7))
        #expect(GitStatus.parse(shortstat: "") == (0, 0))
    }
}
