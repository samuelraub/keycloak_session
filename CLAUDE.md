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

Releases are cut by the `Release` workflow (`workflow_dispatch` with the version). It runs CI,
moves the notes under `[Unreleased]` in `CHANGELOG.md` to the new version, bumps
`lib/keycloak_session/version.rb` and the tag in the README, commits, tags and creates the
GitHub release. So every change that users will notice needs a line under `[Unreleased]`, and
nothing else about a release is done by hand.

Commit messages follow Conventional Commits.
