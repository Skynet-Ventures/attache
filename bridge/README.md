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
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
EOF
launchctl load ~/Library/LaunchAgents/io.skynetventures.attache-bridge.plist
```

## Develop

```bash
bun run dev        # watch mode
bun test
bunx tsc --noEmit
```

Protocol spec: [../docs/protocol.md](../docs/protocol.md).
