<p align="center">
  <img src="docs/logo.svg" width="120" alt="LLMUsage logo">
</p>

# LLMUsage

Just another boring usage tracker, use it or ask your agent to build your own.

```sh
./scripts/rebuild-dev.sh
LLMUSAGE_LAUNCH_UI=0 ./scripts/rebuild-dev.sh
swift build
swift test
swift run LLMUsage_Tracker --once
./scripts/release.sh
```

`rebuild-dev.sh` installs to `/Applications` (removing any old `~/Applications`
copy) and signs with `CODESIGN_IDENTITY` when it is set and in the keychain,
ad-hoc otherwise. `release.sh` requires a real signing identity.

The tracker registers itself as a login item on every launch unless "Auto start
on login" is off, so an ad-hoc rebuild that drops the registration repairs itself.
`swift run` and `--once` never touch login-item registration.

Each machine reads `~/.config/llmusage/runtime.json` (`LLMUSAGE_CONFIG` overrides
the path). Only an explicit server installation contacts providers, runs warm-up
schedules, and scans CLI history. Missing configuration starts a disconnected
client. There is no fallback to local collection.

On m3u:

```json
{"role":"server"}
```

On m4p:

```json
{"role":"client","serverURL":"http://100.106.252.42:9091","serverName":"m3u","keyFile":"~/.keys/llmusage/hub.key"}
```

The client reads quotas and history from the Incandenza hub's authenticated
`/api/usage` and `/api/usage/history` routes. Its admin device key stays in
`~/.keys`. Disconnection preserves the last server snapshot and reports the
connection error; it never runs a local collector or warm-up. Appearance and
menu-bar display settings stay local; provider switches and Warm Up are server-only.

The server publishes `usage.json` after each quota refresh and `history.json`
after a complete history scan, at most once every five minutes. Both files live
in `~/Library/Application Support/LLMUsage/` and are replaced atomically.
