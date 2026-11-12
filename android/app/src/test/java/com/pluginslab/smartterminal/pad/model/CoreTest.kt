package com.pluginslab.smartterminal.pad.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors Tests/SmartTerminalCoreTests (Swift) for the ported types. */
class CoreTest {
    @Test fun parsesBranchUpstreamAndFiles() {
        val out = """
            # branch.oid 1f5f114a9c0e2b6d8e7f3a1b2c4d5e6f7a8b9c0d
            # branch.head main
            # branch.upstream origin/main
            # branch.ab +2 -1
            1 .M N... 100644 100644 100644 aaa bbb CHANGELOG.md
            1 M. N... 100644 100644 100644 aaa bbb VERSION
            2 R. N... 100644 100644 100644 aaa bbb R100 new.swift	old.swift
            u UU N... 100644 100644 100644 100644 a b c conflict.swift
            ? notes.md
            ? scratch/
        """.trimIndent()
        val s = GitStatus.parsePorcelainV2(out)
        assertEquals("main", s.branch)
        assertEquals("1f5f114", s.commit)
        assertTrue(s.hasUpstream)
        assertEquals(2, s.ahead); assertEquals(1, s.behind)
        assertEquals(4, s.changedFiles)
        assertEquals(2, s.untrackedFiles)
        assertFalse(s.isClean)
    }

    @Test fun detachedAndFreshRepos() {
        val detached = GitStatus.parsePorcelainV2("# branch.oid abcdef1234\n# branch.head (detached)\n")
        assertNull(detached.branch)
        assertEquals("abcdef1", detached.commit)
        assertFalse(detached.hasUpstream)
        assertTrue(detached.isClean)
        val fresh = GitStatus.parsePorcelainV2("# branch.oid (initial)\n# branch.head main\n? a.txt\n")
        assertNull(fresh.commit)
        assertEquals("main", fresh.branch)
        assertEquals(1, fresh.untrackedFiles)
    }

    @Test fun parsesShortstat() {
        assertEquals(12 to 4, GitStatus.parseShortstat(" 3 files changed, 12 insertions(+), 4 deletions(-)\n"))
        assertEquals(1 to 0, GitStatus.parseShortstat(" 1 file changed, 1 insertion(+)\n"))
        assertEquals(0 to 7, GitStatus.parseShortstat(" 1 file changed, 7 deletions(-)\n"))
        assertEquals(0 to 0, GitStatus.parseShortstat(""))
    }

    @Test fun claudeTitles() {
        assertEquals(AgentStatus.Busy to "Fix the build", ClaudeTitle.parse("◐ Fix the build"))
        assertEquals(AgentStatus.Busy to "Thinking", ClaudeTitle.parse("⠋ Thinking"))
        assertEquals(AgentStatus.Idle to "Claude Code", ClaudeTitle.parse("✳ Claude Code"))
        assertNull(ClaudeTitle.parse("zsh"))
        assertNull(ClaudeTitle.parse(""))
    }

    @Test fun sessionRecords() {
        val r = ClaudeSessionRecord.parse(
            """{"pid":42,"sessionId":"abc","cwd":"/home/x","status":"shell","name":"\"Kanban\"","nameSource":"user","statusUpdatedAt":1000}"""
        )!!
        assertEquals(AgentStatus.Busy, r.agentStatus)
        assertEquals("Kanban", r.meaningfulName)
        assertTrue(r.isStale(nowMillis = 1000L + 601_000))
        assertFalse(r.isStale(nowMillis = 1000L + 599_000))
        val derived = r.copy(nameSource = "derived")
        assertNull(derived.meaningfulName)
        assertTrue(r.copy(parkedJobId = "j1").isStale(0))
        assertNull(ClaudeSessionRecord.parse("not json"))
    }
}
