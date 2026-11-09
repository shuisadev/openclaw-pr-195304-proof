# Shipped container-session proof — OpenClaw PR #195304

Proves that a container-isolated node worker starts when the bundle, private HOME,
and workspace bind-mount paths all contain the `--mount` field separator (comma),
after the PR's whole-field CSV quoting fix in `src/node-host/node-worker-container-engine.ts`.

## What runs

`run-proof.sh` on `ubuntu-latest` (glibc 2.35, satisfies proc-safe's GLIBC_2.34+ need, real Docker):

1. Checks out `shuisadev/openclaw` at the PR branch and runs `pnpm build cliStartup`.
2. Starts an isolated Gateway on the runner's LAN IP (container workers reject loopback)
   backed by a **real OpenAI-compatible model** (`glm-5.2`); the API key arrives as the
   encrypted repository secret `MODEL_API_KEY` and is written to a `0600` file.
3. Starts the node host with `--session-host` and `nodeHost.workerRuns.isolation=container`.
4. Approves the device + node, then `sessions.create deviceFolder` (comma path) →
   `sessions.dispatch` → `sessions.send`, where the real model performs the turn.
5. Dumps `docker inspect` mounts (comma source/target, bundle read-only, private HOME), the
   marker file on the host **and** inside the container, the worker log, and `chat.history`.
6. Exits non-zero unless the build succeeded, the container mounts the comma path, the host
   marker has the expected content, and the model replied `COMMA_WORKSPACE_PROOF_OK`.

## Trigger

Actions → **shipped-container-session-proof** → Run workflow.
