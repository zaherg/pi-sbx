# pi-sub

pi in a Docker Sandboxes (`sbx`) sandbox, using your Claude and ChatGPT subscriptions plus an OpenRouter API key.
Your settings, extensions and MCP configuration come along; real model credentials stay on the Mac.

## Requirements

- `sbx` signed in, and `jq` on the Mac.
- pi on the Mac signed in to Anthropic: `pi auth check --provider anthropic`.
- The ChatGPT login stored in `sbx`: `sbx secret ls` lists `openai (oauth configured)`.
  If it does not, run `sbx secret set openai --oauth`.
- An OpenRouter API key stored in `sbx`: `sbx secret ls` lists `openrouter`.
  Run `sbx secret import openrouter` to import `OPENROUTER_API_KEY` from your shell, or `sbx secret set openrouter` to enter it interactively.
  The launcher checks for the stored key before creating or replacing a sandbox; it never imports or replaces it automatically.
- For web search, the executor MCP server and TypeSafe, `BRAVE_API_KEY`, `FIRECRAWL_API_KEY`, `EXECUTOR_API_KEY` and `TYPESAFE_API_KEY` set in your shell the first time you run the kit.
- No stored GitHub credential and no SSH agent forwarding, which `sbx` would give every sandbox: `sbx secret rm github` and `sbx settings set ssh.agentForwardingEnabled false`.

## Run

Link the launcher once:

```console
ln -s "$PWD/run.sh" ~/bin/pi-sbx
```

Then, from a project directory:

```console
pi-sbx bear-mcp                       # sandbox pi-bear-mcp, workspace = current directory
pi-sbx                                # sandbox pi-<current folder name>
pi-sbx bear-mcp ~/Code/bear-mcp       # that directory as the workspace instead
pi-sbx --fresh bear-mcp               # remove and recreate it from a fresh sync
SANDBOX=name pi-sbx                   # choose the sandbox name outright
```

An existing sandbox is re-attached as it is, without syncing.
Kit content, credentials and workspaces are fixed when a sandbox is created, so use `--fresh` after changing settings.
Sandbox setup installs the pinned Node 26.13.0 (`n@11.0.0`) and Bun 1.4.4; bump Node and `n` together in `spec.yaml`.
The kit sets a `4g` memory limit for the whole sandbox through `sandbox.resources.memory`.
Measured peak use is 2.3 GB during the first start and 1.2 GB afterwards; `2g` was OOM-killed.
Creating a sandbox takes about two minutes the first time pi starts in it, because pi installs the packages listed in `settings.json` (Linux builds).
Without existing approvals, the first interactive create asks you to approve the ChatGPT login and OpenRouter key.
`sbx` records these approvals in `~/.config/sbx/credentials.yaml`; both are already present on this Mac.
Detached creates withhold credentials without an approval, so approve interactively first or merge these entries into the existing `bindings` mapping without removing other entries:

```yaml
bindings:
    openai:
        oauth:
            domains:
                - auth.openai.com
                - chatgpt.com
    openrouter:
        apiKey:
            domains:
                - openrouter.ai
```

The binding file contains approvals, not secret values; keep it mode `0600`.

`run.sh` does the following on every run:

1. Checks the host-side custom secrets described below and registers any that are missing or out of date.
2. Re-attaches if the sandbox exists, unless `--fresh` was given.
3. Otherwise runs the [safety checks](#safety-checks) and requires the stored OpenRouter key before removing an existing sandbox, runs `sync.sh`, validates the kit, and creates the sandbox with `sbx run --name <name> <kit> <workspace>`.

The kit goes in the agent position: it is a `kind: sandbox` kit, and `--kit` only takes mixins.

Pi starts with `--approve`, so trust-gated project-local configuration and resources load without an interactive prompt.
Only mount projects and install packages whose code you trust to run inside the sandbox.

### npm install scripts

npm 11 skips dependency install scripts unless they are allowed; `ignore-scripts=false` does not lift that.
Setup writes `dangerously-allow-all-scripts=true` and `allow-remote=all` to the agent's `~/.npmrc`, so every install script runs and pi's package installs print no `install-scripts` warning.
A compromised dependency can therefore run code at install time, with the proxy-managed credentials usable.

### Safety checks

`run.sh` refuses to create a sandbox, before it removes an old one, when:

- A workspace contains `~/.pi/agent/auth.json`, `~/.ssh`, `~/.gnupg` or `~/.config/gh` (`$HOME` and `/` included).
- `sbx` stores a global `github` credential: the proxy attaches it to every sandbox's GitHub requests.
- `ssh.agentForwardingEnabled` is `true`: the sandbox could sign with your SSH keys.

`PI_SBX_ALLOW_EXPOSURE=1` skips the last two.

It also mounts the first workspace's `.git/hooks` and `.git/config` read-only, because git runs both on the Mac.
Commits, branches and tags still work; `git config` and `git remote add` inside the sandbox fail.
Other files you run later (package scripts, repo-tracked hooks) and `.env` stay open to the agent, so keep secrets out of mounted projects.

## How the logins work

### ChatGPT

The kit's `openai` OAuth credential uses the login `sbx` stores, and the proxy puts the real token on every request to `chatgpt.com`.
The sandbox only ever holds placeholders in `~/.pi/agent/auth.json`.

pi reads the ChatGPT account id from the access token's JWT payload before every request, so the access-token placeholder is JWT-shaped.
The account id inside it is a dummy: the proxy replaces the `Authorization` header and injects the real `chatgpt-account-id` header itself.

The rendered expiry is fixed at 2100-01-01.
A token refresh started inside the sandbox is not intercepted by `sbx` 0.51 and fails with `invalid_client`, so pi must never decide the token has expired.
Keeping the real token fresh is the host's job; if the login lapses, run `sbx secret set openai --oauth` again.

### Claude

`sbx` 0.51 injects only the first OAuth credential a kit declares: later ones are rendered into the sandbox but never registered with the proxy, without a warning.
Mixins may not declare OAuth either.
So Claude does not use a kit credential.

Instead, `run.sh` registers a custom secret for `api.anthropic.com`.
The sandbox sees `ANTHROPIC_OAUTH_TOKEN=sk-ant-oat01-pi-sub-proxy-managed`, which pi sends as a Bearer token.
The proxy swaps that placeholder for a token printed on demand by pi on the Mac (`pi auth print-bearer-token --provider anthropic --min-expiry 1h`, cached for 30 minutes), so host pi keeps the Claude login refreshed.

`sbx` replays that command from a bare environment, so it carries absolute paths to pi and Node.
`run.sh` re-registers it when either path changes, for example after a Node upgrade.
The placeholder is fixed, so re-registering never breaks a running sandbox.

### OpenRouter

The kit declares an `openrouter` API-key credential with `proxyManaged: true`.
The sandbox sees `OPENROUTER_API_KEY=proxy-managed`, which pi reads for its OpenRouter provider.
The host proxy puts the stored key in the `Authorization: Bearer ...` header on requests to `openrouter.ai`; the real key never enters the sandbox.
This API-key credential works alongside ChatGPT's OAuth credential and Claude's custom secret.

The key comes from the existing `sbx` secret store, not from your shell on every launch.
To replace it, run `sbx secret set openrouter` on the Mac.
An older sandbox does not gain the new kit declaration on re-attach; recreate it with `pi-sbx --fresh <project>` when ready.

### API keys used by tools and providers

`web-search.json`, `web-providers.json` and `mcp.json` read `BRAVE_API_KEY`, `FIRECRAWL_API_KEY` and `EXECUTOR_API_KEY` from the environment.
Pi's TypeSafe provider reads `TYPESAFE_API_KEY`.
`run.sh` stores each one once as a custom secret for its host (`api.search.brave.com`, `firecrawl.nanosite.app`, `executor.mac.srvr.dev`, `api.typesafe.ai`), reading the value from your shell through stdin.
Inside the sandbox each variable holds an `sbx-cs-...` placeholder that the proxy swaps on requests to that host.
To change a key later, run `sbx secret set-custom` for that host and variable yourself.

All of these custom secrets are global, so every sandbox on the Mac sees the placeholders (never the values).
Anything running in the sandbox can make authenticated requests to those hosts, for example through the Firecrawl scraper, so the network allowlist is not an exfiltration boundary.
`sbx secret ls --json` lists them without values; plain `sbx secret ls` prints the first six and last four characters of each, so do not paste it.
`sbx secret rm --placeholder <placeholder> --force` removes one.

## Check a sandbox

```console
sbx exec <name> -- pi -p --model anthropic/claude-haiku-4-5 "Reply with OK"
sbx exec <name> -- pi -p --model openai-codex/gpt-6-astra "Reply with OK"
sbx exec <name> -- pi -p --model openrouter/deepseek/deepseek-v4.1-flash "Reply with OK"
sbx exec <name> -- pi mcp list
sbx policy log <name>
```

`sbx policy log` shows each host the sandbox reached, the hosts it was refused, and whether the proxy intercepted the connection (`forward`) or passed it through (`forward-bypass`).
Credentials are only swapped on intercepted connections.

## What gets synced

`sync.sh` mirrors `~/.pi/agent` into `files/home/.pi/agent`, which becomes `/home/agent/.pi/agent` in the sandbox.
It writes into a staging directory and swaps it in at the end, so files deleted or newly excluded on the Mac leave the kit too.
Run it on its own with `./sync.sh`.

Skipped at the top level:

| Entry | Reason |
| --- | --- |
| `auth.json` | Real tokens; the sandbox gets placeholders from `sbx` instead. Also dropped at any depth. A sync aborts if one would ship, if a staged file holds a credential-shaped string, or if `tar` cannot read a file. |
| `missions/`, `claude-sdk/`, `provider-failover-state.json` | Work history of every host project and usage state with credential hashes. |
| `install/` | The Mac's pi releases; the image ships its own pi. |
| `git/` | Managed package checkouts; pi clones the repositories declared in `settings.json` and installs their dependencies at startup. |
| `npm/`, `bin/` | Built for macOS arm64 (native addons, `fd`); they cannot run in the Linux sandbox. pi installs the packages from `settings.json` at startup and uses the image's `fd` and `rg`. |
| `sessions/`, `cache/`, `web-search-cache/`, `mcp-cache.json`, `mcp-npx-cache.json` | History and caches; the MCP caches contain Mac paths. |
| `langfuse.json` | Tracing keys that no installed extension reads. |
| `.ruff_cache/`, `.serena/`, `tests/` | Tooling for the directory on the Mac. |
| `*.log`, `run-history.jsonl`, `settings_old.json`, `settings.json.*` | Logs and backups. |

Adjusted in the kit's copy only (the files on your Mac are never changed):

- `AGENTS.md` is copied as a regular file; on the Mac it is a symlink to `~/.agents/AGENTS.md`, and kit content may not contain symlinks that point outside the kit.
- Paths into `~/.pi/agent` inside JSON configuration become `/home/agent/.pi/agent`, for example pi-blitz-handoff's recovery directory.
  Project paths stay as they are, because `sbx` mounts workspaces at their Mac paths.
- `mcp.json` keeps remote servers and the stdio servers the image can run (`npx`, `node`, `npm`, `sh`, `bash`, `python3`, `uv`).
  Servers that need a Mac app or binary are dropped, and `sync.sh` prints which ones and why.
  `uvx` becomes `uv tool run`, because the image has `uv` but not the `uvx` alias.

Never commit `files/`: it is your personal configuration.

## Network

`spec.yaml` allows the model APIs, including `openrouter.ai`, npm and GitHub for pi's packages, PyPI for Serena, and the hosts your MCP servers and web search use.
The executor and searxng servers run on your LAN (`*.mac.srvr.dev`) and are reachable from the sandbox.
Anything else follows your local `sbx` policy.

## Local checks

```console
sh -n run.sh sync.sh
shellcheck run.sh sync.sh
sbx kit validate --offline . --json
```

Live verification also returned `OK` from OpenRouter, Claude and ChatGPT, confirmed the OpenRouter placeholder and proxy interception, connected all seven retained MCP servers, and returned Docker documentation through `web_search`.
The first MCP check reported a Chrome DevTools npm extraction failure; a serial retry connected all seven servers.
A domain-filtered web search returned no results; an unfiltered query returned five.

## Known limits

- The `rtk` extension prints one notice per start and disables itself; the `rtk` binary is not in the image.
- `chrome-devtools` connects, but the image has no Chrome, so its browser tools fail when used.
- Serena tries to reach `oraios-software.de`; that is blocked and Serena works without it.
- Never run `/login` inside the sandbox: it writes a real token into the sandbox and defeats the proxy.
- Cloud sandboxes are not covered.
  The cloud secret store accepts only API keys for `anthropic`, and custom secrets there use exact hosts and fixed headers.
