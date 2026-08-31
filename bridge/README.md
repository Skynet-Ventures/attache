# attache-bridge

The daemon half of [Attaché](../README.md). Runs on the machine that runs
[omp](https://omp.sh), owns `omp --mode rpc` processes, and serves the app
protocol over HTTP + WebSocket.

## Run

```bash
bun install
bun run start                      # = bun run src/main.ts serve
```

Flags: `--port` (default 8674), `--host` (default 0.0.0.0), `--omp <path>`
(default: `omp` on PATH).

Startup prints the tailnet address and a one-time pairing code. Other
commands: `attache-bridge devices` lists paired devices.

## State

Everything lives in `~/.attache/` (override with `ATTACHE_DIR`):

| file | contents |
|---|---|
| `auth.json` | paired devices (token **hashes** only) |
| `rules.json` | "always allow" approval rules |
| `push.json` | registered push targets (webhooks) |

omp's own data (`~/.omp/agent`) is read for session listings and written only
through omp itself — except `config.yml` role edits, which are backed up
(`config.yml.bak-attache-*`) before the first write of each run.

## Run at login (macOS)

```bash
cat > ~/Library/LaunchAgents/io.skynetventures.attache-bridge.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.skynetventures.attache-bridge</string>
  <key>ProgramArguments</key><array>
    <string>$(which bun)</string>
    <string>run</string>
    <string>$(pwd)/src/main.ts</string>
    <string>serve</string>
  </array>
  <key>WorkingDirectory</key><string>$(pwd)</string>
  <key>EnvironmentVariables</key><dict>
    <!-- launchd's default PATH can't find omp or bun -->
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/.attache/bridge.log</string>
  <key>StandardErrorPath</key><string>$HOME/.attache/bridge.err.log</string>
</dict></plist>
EOF
launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/io.skynetventures.attache-bridge.plist
```

Fresh pairing codes are printed to `~/.attache/bridge.log` on each start; restart
the agent when you need one:

```bash
launchctl kickstart -k gui/\$(id -u)/io.skynetventures.attache-bridge
```

## Develop

```bash
bun run dev        # watch mode
bun test
bunx tsc --noEmit
```

Protocol spec: [../docs/protocol.md](../docs/protocol.md).
