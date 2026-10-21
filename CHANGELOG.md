# Changelog

## 1.0.2 — 2026-10-21

Fix (`pennylane-access`): section 1 said to load `<toolkit>\lib` or to copy from `<share>\lib`
without saying which copy. On a machine that also holds an older team copy of `pl-api.ps1`, that
copy got loaded — and it still carried the pre-1.0.1 `PLGetAll` defect, so every list came back
empty without any error. The skill now names the plugin's own `lib\` as the only source, warns
against other copies, and adds a guard that refuses a library without the 1.0.1 fix.

## 1.0.1 — 2026-10-09

Fix: `PLGetAll` always returned an empty list, without any error. In `"$script:PLBASE/$path?"`,
PowerShell reads `?` as part of the variable name, so the URL lost its path and its query string.
The path is now interpolated as `$($path)`, and a leading `/` is accepted.

## 1.0.0 — 2026-09-22

First stable release. No functional change from 0.1.0: the skills, the PowerShell library and the
pitfall catalogue have been in daily production use, and the version now says so. Pinning this
toolkit at 1.0.0 is safe.

## 0.1.0

Initial public release.