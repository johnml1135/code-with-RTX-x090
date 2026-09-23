# Client integrations

## Codex

Copy config/codex-profile.template.toml into the user's opt-in Codex profile
location and merge only the named bonsai_local provider/profile according to the
installed Codex configuration schema. Do not change the default provider or
model. Invoke the wrapper only for local work:

    pwsh -NoProfile -File scripts/Invoke-BonsaiCodex.ps1 -ConfigPath <root>\config\server.json

The wrapper health-checks the loopback server, sets a process-scoped
local-only key, selects the bonsai_local profile, and forwards user arguments.
It never writes cloud credentials.

## Claude Code

Invoke:

    pwsh -NoProfile -File scripts/Invoke-BonsaiClaude.ps1 -ConfigPath <root>\config\server.json

The wrapper sets process-scoped ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN with
the literal local-only value, and ANTHROPIC_MODEL. It does not edit global
Claude settings or cloud credentials.

## Herdr

Start Herdr panes as the normal codex and claude agent kinds. Select the local
wrapper or profile inside the pane when local inference is desired. Do not
invent a Bonsai-specific Herdr kind. If a Claude integration hook is outdated,
review the installed Herdr documentation and run the documented integration
refresh command, for example herdr integration install claude, only with
explicit approval.

Herdr and client conversation state is separate from slot files. The server
executes at most three jobs in the preferred mode, or two after fallback;
additional requests wait in the server queue. This does not provide a durable
mapping from a client session to a saved KV slot.
