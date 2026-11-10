# Contributing

Thank you for your interest in contributing. Whether it's a bug report, a new feature, a
correction, or additional documentation, we value feedback and contributions from the community.

Please read this document before submitting any issues or pull requests, so we have all the
information we need to respond effectively.

## Reporting bugs and feature requests

Use the GitHub issue tracker to report bugs or suggest features. Before filing, check existing open
and recently closed issues to make sure somebody else hasn't already reported it. Please include as
much of the following as you can:

- A reproducible test case or series of steps.
- The version of the SDK being used, and the Xcode, Swift and iOS versions.
- Any modifications you've made that are relevant to the bug.
- Anything unusual about your environment or deployment.

Do **not** report security issues in the issue tracker; see [Security](#security-issue-notifications).

## Contributing via pull requests

Contributions via pull requests are much appreciated. Before sending one, please make sure that:

1. You are working against the latest source on the `main` branch.
2. You check existing open and recently merged pull requests to make sure someone else hasn't
   addressed the problem already.
3. You open an issue to discuss any significant work — we would hate for your time to be wasted.

To send us a pull request:

1. Fork the repository and modify the source, focusing on the specific change you are
   contributing. Reformatting all the code makes it hard for us to focus on your change.
2. Install the git hooks once per clone with `make hooks`. The pre-commit hook lints `Sources/`
   and secret-scans the staged files. The pre-push hook runs `make check`.
3. Add tests for your change. Every change ships with its tests, and `make check` must pass.
   Describe user-visible changes under `## [Unreleased]` at the top of `CHANGELOG.md`.
4. Commit with clear messages following [Conventional Commits](https://www.conventionalcommits.org/).
5. Send us a pull request against `main` from a branch (not from your fork's `main`) and answer
   any default questions in the pull request interface.
6. Stay involved in the conversation. CI runs `make check`, `make build-ios` and CodeQL on every
   pull request; they must pass before a merge. Their job names are required checks on `main`, so
   rename a job only together with branch protection. CI also lists the pull request's public API
   changes for the reviewer.

GitHub provides additional documentation on
[forking a repository](https://help.github.com/articles/fork-a-repo/) and
[creating a pull request](https://help.github.com/articles/creating-a-pull-request/).

### What we look for

- **No secrets.** No credentials, account identifiers, internal hostnames or internal links in
  source, tests, docs or commit messages. `Scripts/scan-secrets.sh` checks the files. Nothing
  checks commit messages, so check those yourself.
- **Library code does not crash the host.** No `fatalError`, `precondition`, `assert`, `exit` or
  force-unwrap in `Sources/`. `Scripts/lint.sh` checks this.
- **Sizes scale with Dynamic Type.** No literal font sizes (`.font(.system(size: 15))`) and no
  bare-number dimensions (`.padding(12)`, `.frame(height: 44)`) in view code under `Sources/`
  (files that import SwiftUI or UIKit). Take them from `TranscriptMetrics` in `Theme.swift`, or use
  a `@ScaledMetric`. `Scripts/lint.sh` checks this too.
- **User-facing strings go through the String Catalog**, and new UI is accessible: labelled
  controls, Dynamic Type, VoiceOver.
- **Public API changes are expensive to reverse.** Call them out explicitly in the pull request
  and in `CHANGELOG.md`. `Scripts/check-api-breaks.sh` compares the public API with the previous
  release when a release is tagged, and fails on a break the version number doesn't allow.
- **Dependencies stay small.** A chat-only app must not link the media stack;
  `Scripts/check-build-graph.sh` checks the product graph. Propose any new dependency in an issue
  first.

## Releasing

Releases are git tags, which Swift Package Manager resolves. A tag is SemVer with no `v` prefix
(`0.2.0`, `1.0.0-rc.1`) and equals `Touchpoint.version` in `Sources/TouchpointCore/Touchpoint.swift`.
Before 1.0.0 a minor release may change the public API; a patch release never does. From 1.0.0,
only a major release may.

To release:

1. Open a release pull request into `main` that sets `Touchpoint.version`, renames
   `## [Unreleased]` in `CHANGELOG.md` to `## [X.Y.Z] - YYYY-MM-DD`, and
   raises any dependency floor in `Package.swift` that the release needs. CI must pass. Because
   the pull request changes the version, CI also runs the checks the tag will face: the version
   matches a dated changelog section, and any public API break since the last release fits it.
2. Squash-merge it. `main` keeps a linear history, one commit per pull request.
3. Wait for `main`'s CI run on that commit to pass, then tag it and push the tag:

   ```sh
   git fetch origin && git log -1 origin/main     # the squash-merged release commit
   git tag -a X.Y.Z -m X.Y.Z origin/main
   git push origin X.Y.Z
   ```

   The release workflow checks that the tag is on `main`, equals `Touchpoint.version`, has a dated
   changelog section and that `main`'s CI passed on it, and that any public API break since the
   previous release fits the version. It then publishes a GitHub release with that section as its
   notes (a pre-release before 1.0.0). If the tag was pushed before `main`'s CI finished, re-run
   the Release workflow once it has.

Swift Package Manager resolves a tag as soon as it's pushed, so tag only a green commit. Only
repository admins can create tags, and nobody can move or delete one. A bad release is fixed with a
new patch release, never by moving its tag.

## Finding contributions to work on

Looking at the existing issues is a great way to find something to contribute to. Issues labelled
`help wanted` are a good place to start.

## Code of Conduct

This project has adopted the [Amazon Open Source Code of Conduct](https://aws.github.io/code-of-conduct).
For more information see the [Code of Conduct FAQ](https://aws.github.io/code-of-conduct-faq) or
contact opensource-codeofconduct@amazon.com with any additional questions or comments.

## Security issue notifications

If you discover a potential security issue in this project, we ask that you notify AWS Security via
our [vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/). Please
do **not** create a public GitHub issue. What the SDK protects, and what it expects of your app and
backend, is in the [security guide](docs/SECURITY-GUIDE.md).

## Licensing

See the [LICENSE](LICENSE) file for our project's licensing. We will ask you to confirm the
licensing of your contribution.
