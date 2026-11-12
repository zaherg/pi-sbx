# pi-sub v3

This is the separate schema v3 workload version of `pi-sub`.
The v2 `../spec.yaml` and its launcher are unchanged.

## Sync and run

Refresh the shared Pi configuration and copy it into this build context:

```console
./sync.sh
```

Create or attach to a sandbox from this directory:

```console
sbx run --name pi-v3-my-project . /path/to/project
```

The generated `files/` directory is local configuration and must not be
committed.
Run `./sync.sh` again before recreating a sandbox after host configuration
changes.

The kit uses the same OpenAI and OpenRouter credential bindings and global
custom secrets described in `../README.md`.
Register those host-side secrets before creating the sandbox.
The v3 recipe moves Node and Bun installation into the image build and retains the
v2 resource requests, npm settings, credentials, and runtime network allowlist.
The safety checks in `../run.sh` apply to the v2 kit only.
