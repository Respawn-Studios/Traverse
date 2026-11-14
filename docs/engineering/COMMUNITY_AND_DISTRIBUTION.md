# Community and distribution

The [documentation index](../README.md), [user guides](../guides/README.md) and
[roadmap](../ROADMAP.md) are the maintained project references. Contributors can
start with [Contributing](../../CONTRIBUTING.md) and [development setup](DEVELOPMENT_SETUP.md).
Keep documentation available in the repository rather than depending on a
separate hosted Wiki or website.

## Community channels

Use [Issues](https://github.com/Respawn-Studios/Traverse/issues) for reproducible
bugs and concrete changes, and
[Discussions](https://github.com/Respawn-Studios/Traverse/discussions) for usage
questions and exploratory ideas. The
[Respawn Studios community](https://discord.gg/UdKp2uQBQy) provides another
conversation entry point.

Include the relevant version, reproducible steps, expected/actual behavior and
focused evidence. Remove credentials, personal paths and file contents from
examples and screenshots. Report vulnerabilities through the
[security policy](../../SECURITY.md), rather than a public issue or discussion.
The [privacy guide](../../PRIVACY.md) explains application data boundaries.

Half-formed ideas are welcome in Discussions. For a contribution, agree on the
user task and a useful first change, then build the complete flow using the
existing app and tests. Keep the feature guide in step with the code, and put
future ideas on the roadmap. The [engineering guide](README.md) explains how to
choose checks that matter for your change.

## Dependency maintenance

Dependency discovery, vulnerability alerts and automated update pull requests
are separate features. Review an alert or proposed update against the actual
locked dependency, affected behavior and release impact before merging. Keep
source provenance, license notices and reproducible setup current. Enabling an
alert or bot does not qualify the resulting application.
[GitHub dependency-security guidance](https://docs.github.com/en/code-security/getting-started/quickstart-for-securing-your-repository)

## Release access

GitHub release access follows repository permissions: anyone with repository
read access can view its releases. A **prerelease** label communicates maturity;
it does not add a separate tester-only audience or per-release privacy role.
Verify repository visibility and the intended audience before publishing assets.
[GitHub release access](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)

Drafting, attaching assets and publishing a release are distinct actions. Use a
draft to prepare the reviewed notes, matching binaries, source and checksums;
verify the final assets before publishing. Repository visibility changes and
update-feed publication are separate administrative actions, not side effects
of preparing an archive.
[GitHub release management](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)

Follow [Releasing Traverse](OPEN_SOURCE_RELEASE.md) for source, notices, symbols,
artifact identity and channel separation. The current public/direct producer
capability is shipping-held by its admission checks; a locally exported app or
prepared appcast does not bypass that boundary.

## Voluntary development support

The [funding metadata](../../.github/FUNDING.yml) points to Respawn Studios'
coffee jar. Support helps us keep building; everyone gets the same free app.
Bug reports, thoughtful ideas and contributions are welcome either way.

Contributors keep their copyright and contribute under GPLv3 without a CLA. Project and
dependency terms live in [Licensing](../../LICENSING.md), and commercial
permissions have their [own page](../../COMMERCIAL-LICENSING.md).
