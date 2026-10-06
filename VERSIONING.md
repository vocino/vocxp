# Versioning

Tag-driven semver, same scheme as VocGear and VocWarbank.

- Tags look like `v0.1.0`. Pushing a tag runs the release
  workflow: BigWigs packager builds the zip, attaches it to a
  GitHub release, and uploads to CurseForge and Wago.
- `## Version: @project-version@` in the toc is replaced at
  package time; never hand-edit a version number.
- No tag until V approves the release.
