# SwiftTerm

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) v1.20.0 (`5d14406`), its library sources and license only,
with [PR #728](https://github.com/migueldeicaza/SwiftTerm/pull/728) applied: the Core Graphics renderer lays out every
row left to right, so a row whose first letter is Hebrew or Arabic is no longer drawn against the right edge. Go back to
the upstream package (`Package.swift`, `App/project.yml`) once a release includes that change.
