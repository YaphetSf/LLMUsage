<p align="center">
  <img src="docs/logo.svg" width="120" alt="LLMUsage logo">
</p>

# LLMUsage

Just another boring usage tracker, use it or ask your agent to build your own.

```sh
./scripts/rebuild-dev.sh
swift build
swift test
./scripts/release.sh
```

`rebuild-dev.sh` installs to `/Applications` (removing any old `~/Applications`
copy) and signs with `CODESIGN_IDENTITY` when it is set and in the keychain,
ad-hoc otherwise. `release.sh` requires a real signing identity.

The tracker registers itself as a login item on every launch unless "Auto start
on login" is off, so an ad-hoc rebuild that drops the registration repairs itself.
`swift run` and `--once` never touch login-item registration.
