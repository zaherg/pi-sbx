# pi-sub

pi in a Docker Sandboxes (`sbx`) sandbox, using Claude and ChatGPT subscriptions plus an OpenRouter API key.
Settings, extensions and MCP configuration come along; real credentials stay on the host.

## Requirements

- `sbx` signed in, and `jq` on the host.
- Host pi signed in to Anthropic: `pi auth check --provider anthropic`.
- The ChatGPT login stored in `sbx`: `sbx secret set openai --oauth`.
- An OpenRouter key stored in `sbx`: `sbx secret import openrouter` or `sbx secret set openrouter`.
- Optional tool keys in your shell on the first run: `BRAVE_API_KEY`, `FIRECRAWL_API_KEY`, `EXECUTOR_API_KEY`, `TYPESAFE_API_KEY`.
- No stored GitHub credential and no SSH agent forwarding: `sbx secret rm github` and `sbx settings set ssh.agentForwardingEnabled false`.

## Run

Link the launcher once:

```console
ln -s "$PWD/run.sh" ~/bin/pi-sbx
```

Then, from a project directory:

```console
pi-sbx my-project                # sandbox pi-my-project, workspace = current directory
pi-sbx                           # sandbox pi-<current folder name>
pi-sbx my-project ~/Code/other   # that directory as the workspace instead
pi-sbx --fresh my-project        # remove and recreate it from a fresh sync
SANDBOX=name pi-sbx              # choose the sandbox name outright
```

An existing sandbox is re-attached as it is, without syncing.
Kit content, credentials and workspaces are fixed at creation, so use `--fresh` after changing settings.
The first start takes a few minutes, because pi installs the packages listed in `settings.json`.
Setup also installs the pinned [rtk](https://www.rtk-ai.app) binary and runs `rtk init --agent pi --global`, so the synced `extensions/rtk.ts` has its binary inside the sandbox.

The first interactive create asks you to approve the ChatGPT login and the OpenRouter key.
Detached creates withhold unapproved credentials, so approve interactively first or add the bindings to `~/.config/sbx/credentials.yaml` (mode `0600`):

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

Pi starts with `--approve`, and setup lets every npm install script run.
Only mount projects and install packages whose code you trust to run inside the sandbox.

### Project dependencies

`run.sh` mounts a private, disk-backed volume over the primary workspace's root `node_modules` inside the VM.
The host keeps its macOS dependencies; the VM installs its own Linux dependencies.
Source files, manifests and lockfiles remain shared.

At creation, setup installs project dependencies inside the VM as the agent user, after preparing the volume, tools and npm proxy settings:

- `bun.lock` present: run `bun --no-env-file install`.
- Otherwise, `package-lock.json` present: run `npm install`.
- Neither present: skip project installation.

Bun wins when both lockfiles exist, and an installation failure aborts setup.
These commands can update shared lockfiles; install scripts can also write to shared project files.
Installation does not run on reattach or restart; rerun it inside the VM after dependency changes.
The volume survives stop/start, but `--fresh` discards it and installs dependencies again during creation.
Existing sandboxes must be recreated to gain the volume; save any needed sandbox-only files before doing so.
If the host has no `node_modules`, creation adds an empty mountpoint directory there, not the Linux packages.
The launcher refuses a symlink or non-directory at that path, and setup refuses a mount that is not the expected private ext4 volume.

Only the primary workspace's root `node_modules` is isolated.
Additional workspaces, nested package directories and native build caches remain shared.
Direct `sbx` callers must pass `--kit-arg workspace=<absolute-primary-workspace>`; the default `/home/agent/workspace` does not cover a host-mounted project.

### Safety checks

`run.sh` refuses to create a sandbox, before it removes an old one, when:

- A workspace contains `~/.pi/agent/auth.json`, `~/.ssh`, `~/.gnupg` or `~/.config/gh`.
- `sbx` stores a global `github` credential.
- `ssh.agentForwardingEnabled` is `true`.

`PI_SBX_ALLOW_EXPOSURE=1` skips the last two.

The first workspace's `.git/hooks` and `.git/config` are mounted read-only, because git runs both on the host.
Other files in the workspace, including `.env`, stay open to the agent, so keep secrets out of mounted projects.

## How the logins work

The sandbox only holds placeholders; the `sbx` proxy swaps in the real credential on requests to the matching host.

| Login | Mechanism |
| --- | --- |
| ChatGPT | The kit's OAuth credential, rendered as a placeholder `auth.json` that never expires. If the login lapses, run `sbx secret set openai --oauth` again. |
| Claude | A custom secret for `api.anthropic.com`, filled on demand by host pi (`pi auth print-bearer-token`). A kit can register only one OAuth credential, and ChatGPT uses it. |
| OpenRouter | A proxy-managed API key from the `sbx` secret store. Replace it with `sbx secret set openrouter`. |
| Tool keys | Custom secrets that `run.sh` registers once from your shell. Change one later with `sbx secret set-custom`. |

Custom secrets are global, so every sandbox on the host can make authenticated requests to those hosts.
`sbx secret ls` prints part of each value, so do not paste its output.
Never run `/login` inside the sandbox: it writes a real token into the sandbox and defeats the proxy.

## Check a sandbox

```console
sbx exec <name> -- pi -p --model <provider/model> "Reply with OK"
sbx exec <name> -- pi mcp list
sbx policy log <name>
```

`sbx policy log` shows the hosts reached and refused, and whether the proxy intercepted each connection.
Credentials are only swapped on intercepted connections.

## What gets synced

`sync.sh` mirrors `~/.pi/agent` into `files/home/.pi/agent`, which becomes `/home/agent/.pi/agent` in the sandbox.
Run it on its own with `./sync.sh`.
The files on the host are never changed.

- Skipped: `auth.json`, sessions, caches, logs, backups, work history, and anything built for the host platform (`install/`, `npm/`, `bin/`, `git/`).
- A sync aborts if a staged file holds a credential-shaped string or `tar` cannot read a file.
- `AGENTS.md` is copied as a regular file, because kit content may not contain symlinks that point outside the kit.
- Paths into `~/.pi/agent` inside JSON configuration are rewritten to the sandbox path.
- `mcp.json` keeps remote servers and the stdio servers the image can run; `sync.sh` prints the ones it drops.

Never commit `files/`: it is personal configuration.

## Network

`spec.yaml` allows the model APIs, npm, GitHub (including release assets, for the rtk install), PyPI, and the hosts the MCP servers and web search use.
Anything else follows the local `sbx` policy.

## Local checks

Use [`act`](https://nektosact.com/installation/index.html) to run the [validation workflow](.github/workflows/validate.yml) locally in Docker, including its pinned tool downloads and checksum checks.
The installation guide covers macOS, Linux and Windows; on macOS with Homebrew:

```console
brew install act
```

Start Docker, then run from the repository root:

```console
act workflow_dispatch -W .github/workflows/validate.yml \
  --container-architecture linux/amd64 \
  -P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04 \
  --rm
```

The [community runner image](https://github.com/catthehacker/docker_images) includes Docker CLI and Buildx; the v3 build also needs access to the host Docker daemon.
`linux/amd64` matches the workflow's pinned binaries, including when running on Apple Silicon.
To run one job, add `-j lint`, `-j kit-v2` or `-j kit-v3`.

For quick checks with tools already installed on the host:

```console
git ls-files -z '*.sh' | xargs -0 shellcheck
actionlint
sbx kit validate --offline .
mkdir -p v3/files/home/.pi/agent
docker buildx build v3 -f v3/pi-sub.yaml --output type=cacheonly
```

GitHub runs the workflow on pushes to `main` and on pull requests.
`act` does not reproduce every [GitHub runner feature](https://nektosact.com/not_supported.html), so a local pass does not replace the hosted run.

> **Note:** the workflow only validates and builds the kits.
> It never creates a sandbox, runs `sync.sh` or uses provider credentials, and it builds v3 against an empty configuration.
> Logins, MCP servers and package installs still need a manual run with `pi-sbx --fresh`.

## Known limits

- Existing sandboxes keep the old kit content; recreate with `pi-sbx --fresh` to get the rtk binary.
- `chrome-devtools` connects, but the image has no Chrome, so its browser tools fail when used.
- Serena tries to reach `oraios-software.de`; that is blocked and Serena works without it.
- Cloud sandboxes are not covered.
