package uhp_server

import std.unittest.*
import std.unittest.testmacro.*

let SAMPLE = """
[server]
bind = "0.0.0.0"
port = 9000

[[tokens]]
token = "t1"
principal = "alice"

[[harnesses]]
id = "echo"
name = "自检"
kind = "scripted"
reply = "pong"
delay_ms = 5
"""

@Test
func config_parses_server_tokens_harnesses(): Unit {
    let cfg = parseConfig(SAMPLE)
    @Expect(cfg.server.bind, "0.0.0.0")
    @Expect(cfg.server.port, 9000)
    @Expect(cfg.tokens.size, 1)
    @Expect(cfg.tokens[0].token, "t1")
    @Expect(cfg.tokens[0].principal, "alice")
    @Expect(cfg.harnesses.size, 1)
    @Expect(cfg.harnesses[0].id, "echo")
    @Expect(cfg.harnesses[0].kind, "scripted")
    @Expect(cfg.harnesses[0].reply, "pong")
    @Expect(cfg.harnesses[0].delay_ms, 5)
}

@Test
func factory_builds_scripted_harness(): Unit {
    let harnesses = buildHarnesses(parseConfig(SAMPLE))
    @Expect(harnesses.size, 1)
    @Expect(harnesses[0].id, "echo")
    @Expect(harnesses[0].base, "scripted")
    @Expect(harnesses[0].defaultModel, "auto")
}

@Test
func factory_rejects_unknown_kind(): Unit {
    let toml = """
    [[harnesses]]
    id = "x"
    kind = "telepathy"
    """
    var threw = false
    try {
        let _ = buildHarnesses(parseConfig(toml))
    } catch (e: ServerConfigError) {
        threw = true
        @Expect(e.message.contains("未知 kind"), true)
    }
    @Expect(threw, true)
}

@Test
func factory_rejects_duplicate_ids(): Unit {
    let toml = """
    [[harnesses]]
    id = "dup"
    kind = "scripted"

    [[harnesses]]
    id = "dup"
    kind = "scripted"
    """
    var threw = false
    try {
        let _ = buildHarnesses(parseConfig(toml))
    } catch (e: ServerConfigError) {
        threw = true
        @Expect(e.message.contains("重复"), true)
    }
    @Expect(threw, true)
}

@Test
func factory_rejects_acp_without_command(): Unit {
    let toml = """
    [[harnesses]]
    id = "dsh"
    kind = "acp"
    """
    var threw = false
    try {
        let _ = buildHarnesses(parseConfig(toml))
    } catch (e: ServerConfigError) {
        threw = true
        @Expect(e.message.contains("command"), true)
    }
    @Expect(threw, true)
}

@Test
func factory_skips_disabled_harness(): Unit {
    let toml = """
    [[harnesses]]
    id = "on"
    kind = "scripted"

    [[harnesses]]
    id = "off"
    kind = "scripted"
    enabled = false
    """
    let harnesses = buildHarnesses(parseConfig(toml))
    @Expect(harnesses.size, 1)
    @Expect(harnesses[0].id, "on")
}

@Test
func config_reads_session_ttl(): Unit {
    let toml = """
    [server]
    port = 9001
    session_ttl_seconds = 1800
    """
    let cfg = parseConfig(toml)
    @Expect(cfg.server.session_ttl_seconds, 1800)
    // 缺省 = 不回收
    let dflt = parseConfig("[server]\nport = 9002\n")
    @Expect(dflt.server.session_ttl_seconds, 0)
}

