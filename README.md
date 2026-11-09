# Shipped container-session proof — OpenClaw PR #195304

Proves that a container-isolated node worker starts when the bundle, private HOME,
and workspace bind-mount paths all contain the `--mount` field separator (comma),
after the PR's whole-field CSV quoting fix in `src/node-host/node-worker-container-engine.ts`.

## What runs

`run-proof.sh` on `ubuntu-latest` (glibc 2.35, satisfies proc-safe's GLIBC_2.33+ need, real Docker):

1. Checks out `shuisadev/openclaw` at the PR branch and tries a real `pnpm build`.
2. If the real dist is unavailable, installs published `openclaw@2026.11.1` and applies the
   PR's exact `mountField`/`bindMount` encoder to the container-engine chunk.
3. Starts a mock OpenAI-compatible provider and an isolated Gateway bound to the runner's LAN IP
   (container workers reject loopback).
4. Starts the node host with `--session-host` and `nodeHost.workerRuns.isolation=container`.
5. Approves the device + node, then `sessions.create deviceFolder` (comma path) → `sessions.dispatch`
   → `sessions.send`.
6. Dumps `docker inspect` mounts (comma source/target, bundle read-only, private HOME), the marker
   file on the host **and** inside the container, the mock request log, and `chat.history`.

## Trigger

Actions → **shipped-container-session-proof** → Run workflow.
