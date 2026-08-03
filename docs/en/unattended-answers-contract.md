# The `UA_<KEY>` unattended-answers contract

This document defines the stability guarantee for the `--unattended --answers`
interface (`setup.sh --unattended --answers my-answers.env`), for anyone
building automation on top of it — kickstart `%post`, CI provisioning, or a
GUI/web frontend such as Tune OS's installer.

## Source of truth

**`extras/answers-example.env` is the only authoritative list of keys.**
It is generated and maintained alongside the modules themselves, so it never
drifts from what the wizard actually reads. Any integration should parse (or
vendor, pinned to a release tag) that file rather than hand-copying key names
into external code — new optional keys then surface automatically without a
consumer-side code change.

The x86 sibling ([fedora-audiophile-setup](https://github.com/cometdom/fedora-audiophile-setup))
has its own `extras/answers-example.env`, kept at functional parity but not
byte-identical: module file-prefixes differ where module sets diverge (e.g.
`14-ram-mode` here vs `13-ram-mode` there, because this repo inserts
`13-pi-tweaks`), and this repo adds `UA_PI_TWEAKS*` keys with no x86
equivalent. Consumers targeting both platforms should read both files rather
than assume one is a strict subset of the other.

## Stability guarantee (semver-backed)

- A **key name and its accepted value format are part of the public API**
  once shipped in a tagged release.
- A **MINOR** release (`vX.Y.0`) may add new keys (always with a safe
  default equal to the interactive prompt's default) or a new module. It
  will not remove or repurpose the meaning of an existing key.
- A **MAJOR** release (`vX.0.0`) is the only place a key may be renamed,
  removed, or have its meaning changed — and any such change is called out
  explicitly in that release's Roadmap/tag notes with a migration note.
- A key scheduled for removal gets a **deprecation window**: it keeps
  working (with a `log_warn`) for at least one full MINOR release cycle
  before being dropped in the next MAJOR.
- Module **file-prefix numbers are not part of this contract** — they can
  differ between the x86 and RPi repos (see above) and are not guaranteed
  stable across releases. Never hardcode `--only 13` / `--only 14`; use the
  module's slug (e.g. `--only ram-mode`) if selecting a single module.

## Recommended integration pattern

1. Build/generate an answers file from user input (a GUI, a config
   management tool, whatever) rather than exporting `UA_*` vars ad hoc —
   easier to diff, log, and attach to a support request.
2. Validate first with `sudo ./setup.sh --dry-run --unattended --answers
   file.env` — every prompt resolution is logged with the value it took,
   nothing on the host changes. This is the integration test harness: run
   it in CI against a pinned answers file to catch a contract break before
   it reaches a real image build.
3. Run for real: `sudo ./setup.sh --unattended --answers file.env`. An
   answer that a prompt loop keeps rejecting aborts the run (fail-fast)
   instead of hanging — treat a non-zero exit as "stop the image build",
   not as "retry blindly."

## Current release

At the time of writing: **v2.3.2** (x86 and RPi, kept in version lockstep).
Pin integrations to a tag, not `main`, for anything that ships to end users.
