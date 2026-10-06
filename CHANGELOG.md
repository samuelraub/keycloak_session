# Changelog

## [Unreleased]

## [0.2.1] - 2026-10-06

- Allows `omniauth-rails_csrf_protection` 2.x.

## [0.2.0] - 2026-10-05

Run `bin/rails keycloak_session:install:migrations db:migrate` after upgrading.

- Signing out redirects the browser to Keycloak's logout page (RP-initiated
  logout) with the stored ID token as `id_token_hint`, instead of posting the
  refresh token to it, a legacy format Keycloak advises against. Register
  `post_logout_redirect_uri` (default: `login_path`) with the client as a
  valid post logout redirect URI.
  - The sign-out button has to be a plain form post (`data: {turbo: false}`):
    Turbo and fetch cannot follow the redirect to Keycloak.
  - `TokenSet#end_session` is now `logout_url!`: it drops the row and returns
    the URL, and no longer tells Keycloak anything itself. `Client#end_session`
    is gone, and nothing replaces it for ending a session from the server.
  - `fake_keycloak.ended_refresh_tokens` is gone; `fake_keycloak.logout_page`
    switches the redirect on in tests.

- `encrypt_tokens` stores the tokens through Active Record encryption.
- An unreachable Keycloak no longer ends sessions. `Client#refresh` and the
  verifier raise `KeycloakSession::Unavailable` instead of reporting a refusal.
  Only `invalid_grant` counts as one; a wrong client secret or a rate limit
  does not.
- After a request Keycloak did not answer, the next ones are skipped for ten
  seconds instead of each waiting for the timeout.
- A token signed with a key that may not be looked up yet, because the forced
  refetch of the key set is rationed, counts as unavailable, not as rejected.
- Parallel requests no longer spend the same refresh token twice.
- Back-channel logout honours `sid`: only the token set of that Keycloak
  session goes, and a token without `sub` is accepted. Token sets store the
  `sid` of their access token.
- Tokens without `exp` are rejected, as are logout tokens without `iat` or
  `jti`.
- A logout token with a malformed header is answered with 400 instead of 500.
- `OmniAuth.config.on_failure` of the host app keeps handling other providers.
- A missing setting is reported by name at boot, `issuer` included.
- `TestHelpers.reset` clears the cached discovery document and key set, and
  `fake_keycloak.down` now covers the token endpoint too.

## [0.1.0] - 2026-10-05

- Initial release: sign-in through OmniAuth with PKCE, per-login token sets,
  access token verification against the realm's keys, refresh, logout at
  Keycloak, back-channel logout, and test helpers.
