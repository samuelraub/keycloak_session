# keycloak_session

Keycloak login for Rails apps, as an engine: sign-in, a server-side token set
per login, token refresh, logout through Keycloak and back-channel logout.

The app keeps a config block, its user lookup and its login and logout
buttons.

## How access is decided

Every request verifies the stored access token against the realm's keys:
signature, expiry, issuer and audience. The audience is the access gate, and
it takes two things in Keycloak:

- a client scope with an audience mapper that adds the client to `aud`, and
- on that same client scope's *Scope* tab, the client's role as a role scope
  mapping.

The mapper itself is unconditional. The role scope mapping is what makes it
conditional: Keycloak only applies a client scope, mappers included, to users
holding one of its mapped roles. Without the mapping every realm user gets
the audience and the gate is open. Nothing else may add the client to `aud`.

Do not swap `aud` for `azp`: `azp` names the client that asked for the token,
whoever the user is.

An expired access token is refreshed inline. If Keycloak refuses the refresh,
or the new token comes back without the audience, the session ends. While
Keycloak cannot be reached nobody is signed in, but the session is kept and
works again once Keycloak is back.

## Installation

```ruby
# Gemfile
gem "keycloak_session", github: "samuelraub/keycloak_session", tag: "v0.2.0"
```

```sh
bin/rails keycloak_session:install:migrations db:migrate
```

```ruby
# config/initializers/keycloak_session.rb
KeycloakSession.configure do |config|
  config.issuer = "https://kc.example.com/realms/main"
  config.client_id = "myapp"
  config.client_secret = ENV.fetch("KEYCLOAK_CLIENT_SECRET")
  config.redirect_uri = "https://myapp.example.com/auth/keycloak/callback"
  config.resolve_user = ->(claims) { User.find_by(oidc_id: claims["sub"]) }
end
```

```ruby
# config/routes.rb
mount KeycloakSession::Engine, at: "/auth"
get "login", to: "sessions#new"
```

```ruby
class ApplicationController < ActionController::Base
  include KeycloakSession::Authentication
  before_action :require_login
end
```

The engine has to be mounted at `/auth`; OmniAuth owns that prefix.

The login page is yours. Its button posts to `/auth/keycloak` with a CSRF
token and Turbo off, the sign-out button posts to `/auth/logout`:

```erb
<%= button_to "Sign in", "/auth/keycloak", data: {turbo: false} %>
<%= button_to "Sign out", "/auth/logout", data: {turbo: false} %>
```

To drop a user's logins along with the user:

```ruby
has_many :keycloak_token_sets, class_name: "KeycloakSession::TokenSet", dependent: :destroy
```

## Configuration

| Setting | Default | |
|---|---|---|
| `issuer` | required | The realm URL. Every endpoint is discovered from it. |
| `client_id`, `client_secret` | required | A confidential client. |
| `redirect_uri` | required | `https://<app>/auth/keycloak/callback` |
| `post_logout_redirect_uri` | `login_path` on the host of `redirect_uri` | Where Keycloak sends the browser after a sign-out. |
| `resolve_user` | required | Called with the verified access token claims. Returns the user, or nil to refuse. |
| `audience` | `client_id` | The value that must be in `aud`. |
| `scopes` | `openid email profile` | |
| `user_class` | `"User"` | |
| `login_path` | `"/login"` | Where signed-out visitors go. |
| `after_login_path` | `"/"` | |
| `enabled` | `true` | False leaves the provider out of the middleware stack. |
| `encrypt_tokens` | `false` | Encrypts the stored tokens, see below. |

### Encrypting the stored tokens

Access and refresh tokens are stored as they come. With `encrypt_tokens` they
go through [Active Record encryption](https://guides.rubyonrails.org/active_record_encryption.html),
so the app needs its keys set up (`bin/rails db:encryption:init`); without
them it refuses to boot. Set it in the initializer, it is read once.

Switching it on or off needs no migration. Token sets written the other way
cannot be read, so their users sign in again and the old rows go with the
usual cleanup. The same holds for a wrong key, and nothing is deleted: with
the right key back, the sessions work again.

## Keycloak client

- Valid redirect URI: `https://<app>/auth/keycloak/callback`
- Valid post logout redirect URI: `https://<app>/login`
- Backchannel logout URL: `https://<app>/auth/backchannel-logout`
- A client scope with an audience mapper for the client, as described above.

## A second login

`current_user` is `keycloak_user` by default. An app with another way in
overrides it, and `request_login` for requests that should not be redirected:

```ruby
def current_user
  @current_user ||= api_user || keycloak_user
end

def request_login
  request.format.json? ? head(:unauthorized) : super
end
```

## Testing

```ruby
require "keycloak_session/test_helpers"
KeycloakSession::TestHelpers.install!   # once, after the app has booted

include KeycloakSession::TestHelpers
KeycloakSession::TestHelpers.reset      # between tests
```

Tokens are really signed and really verified; only the HTTP calls to Keycloak
are answered from memory.

```ruby
keycloak_sign_in(sub: user.oidc_id)                 # request tests
mock_keycloak_login(sub: user.oidc_id)              # system tests, then click your button
keycloak_sign_in(sub: user.oidc_id, aud: "account") # a user without access

fake_keycloak.refreshed_tokens = {access_token: fake_keycloak.access_token(sub: "abc")}
fake_keycloak.down = true
fake_keycloak.logout_token(sub: "abc")
fake_keycloak.logout_page = true
```

Signing out redirects the browser to Keycloak's logout page. The fake names
none unless `logout_page` is set, so in tests a sign-out lands on
`login_path` directly and a system test never leaves the app.

## Development

```sh
bundle install
bundle exec rake   # specs and standard
```

`RAILS_VERSION` and `JWT_VERSION` select other versions, as CI does.

## License

MIT.
