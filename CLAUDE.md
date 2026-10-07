# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Rails engine, shipped as a gem, that signs users in through Keycloak (OIDC) and keeps their
token sets. It is not on rubygems.org: the apps that use it (`habits`, `splitty`) pin a git tag.
`README.md` documents the behaviour and the configuration.

## Commands

```sh
bundle install
bundle exec rake            # specs and standard, as CI does
bundle exec rake spec
bundle exec rake standard
PLAINTEXT_TOKENS=1 bundle exec rake spec                              # CI's second pass
RAILS_VERSION="~> 8.1.0" bundle update && bundle exec rake spec       # another Rails
```

`Gemfile.lock` is not committed, so CI resolves the dependencies fresh on every run.

## Supported versions

The CI matrix in `.github/workflows/ci.yml` is the statement of what is supported: three
Ruby/Rails pairs, the oldest of them with the oldest `jwt`. `RAILS_VERSION` and `JWT_VERSION`
select them through the `Gemfile`. When a constraint in the gemspec moves, move the matrix
with it.

Dependabot ignores `rails` (the matrix drives it) and `json` (capped in the `Gemfile` on
purpose; the comment there says why).

## Releasing

A release has two steps, because `main` only changes through pull requests:

1. A pull request that makes `main` say the new version: `VERSION` in
   `lib/keycloak_session/version.rb`, the entries under `[Unreleased]` in `CHANGELOG.md` moved
   under a `## [x.y.z] - date` heading (leaving `[Unreleased]` empty), and the `tag:` line in the
   README.
2. The `Release` workflow (`workflow_dispatch` on `main`). It checks those three against each
   other and against the existing tags, runs CI, then creates the tag `vx.y.z` and a GitHub
   release with that changelog section as notes. It commits nothing; `dry_run` only checks.

So every change that users will notice needs a line under `[Unreleased]` when it is made.

Commit messages follow Conventional Commits.
