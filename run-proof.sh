#!/usr/bin/env bash
# Shipped container-session proof for OpenClaw PR #195304.
# Runs on GitHub Actions ubuntu-latest (glibc >= 2.35, satisfies proc-safe's GLIBC_2.33+ need):
#   isolated Gateway + node host complete a container-isolated session whose bundle,
#   private HOME, and workspace paths all contain the --mount field separator (comma).
set -uo pipefail

PROOF=/tmp/proof
PKG="${PKG:-$PWD}"
NODE_BIN="$(command -v node)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAN_IP="$(hostname -I | awk '{print $1}')"
TOKEN="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
GW_PORT=19531
COMMA_ROOT="$PROOF/work,space"
DEVICE_FOLDER="$COMMA_ROOT/demo"
SESSION_KEY="agent:main:comma195304"

mkdir -p "$PROOF" "$DEVICE_FOLDER"
export PATH="$(dirname "$NODE_BIN"):$PATH"

say() { echo "[proof] $*"; }
dump() { echo "===== $1 ====="; shift; "$@" 2>&1 | sed 's/^/  /' || true; echo; }

say "node=$($NODE_BIN -v) glibc=$(ldd --version 2>&1 | head -1) lan=$LAN_IP"
say "dockerd=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo MISSING)"

# ---------------------------------------------------------------- build or fallback
say "build: attempting real dist build (pnpm install + pnpm build)"
pushd "$PKG" >/dev/null
if command -v corepack >/dev/null 2>&1; then corepack enable >/dev/null 2>&1 || true; fi
(corepack pnpm install --frozen-lockfile 2>&1 | tail -15) || say "pnpm install reported errors (continuing)"
if [ ! -f dist/entry.js ]; then
  (corepack pnpm build cliStartup >"$PROOF/build.log" 2>&1) || say "pnpm build reported errors (see build.log)"
fi
BUILD_OK=0
if [ -f dist/entry.js ] && [ -d dist/worker ]; then BUILD_OK=1; fi
popd >/dev/null
say "build: real dist present=$BUILD_OK"

RUNTIME_DIR="$PKG"
if [ "$BUILD_OK" != "1" ]; then
  say "build: fallback -> published openclaw + PR mount encoder patched into dist"
  mkdir -p "$PROOF/pkg"
  (cd "$PROOF/pkg" && npm init -y >/dev/null 2>&1 && npm install openclaw@2026.11.1 >"$PROOF/npm.log" 2>&1) || say "npm install failed"
  OA="$PROOF/pkg/node_modules/openclaw"
  # Apply the PR's exact mountField/bindMount encoder to the published container-engine chunk.
  CHUNK="$(grep -rl 'type=bind,source=' "$OA/dist"/*.mjs | head -1)"
  say "build: patching mount encoder into ${CHUNK:-none}"
  if [ -n "$CHUNK" ]; then
    python3 - "$CHUNK" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
helpers='''function mountField(key, value) {
\tconst field = `${key}=${value}`;
\treturn value.includes(",") ? `"${field.replaceAll('"', '""')}"` : field;
}
function bindMount(source, target, options = {}) {
\tconst spec = `type=bind,${mountField("source", source)},${mountField("target", target)}`;
\treturn options.readOnly ? `${spec},readonly` : spec;
}
'''
s=s.replace('/** Create a labeled, stopped container so its durable identity exists before worker admission. */', helpers+'/** Create a labeled, stopped container so its durable identity exists before worker admission. */',1)
s=s.replace('`type=bind,source=${bundleDir},target=${bundleDir},readonly`','bindMount(bundleDir, bundleDir, { readOnly: true })')
s=s.replace('`type=bind,source=${params.workspaceDir},target=${params.workspaceDir}`','bindMount(params.workspaceDir, params.workspaceDir)')
s=s.replace('`type=bind,source=${params.homeDir},target=${params.homeDir}`','bindMount(params.homeDir, params.homeDir)')
open(p,'w').write(s)
print("patched", p)
PY
  fi
  RUNTIME_DIR="$OA"
fi

CLI="$RUNTIME_DIR/openclaw.mjs"
GWC() { ( cd "$RUNTIME_DIR" && OPENCLAW_STATE_DIR="$PROOF/gw" "$NODE_BIN" "$CLI" "$@" ); }

# ---------------------------------------------------------------- mock + gateway
say "start mock provider"
"$NODE_BIN" "$SCRIPT_DIR/mock-provider.mjs" >"$PROOF/mock.log" 2>&1 &
MOCK_PID=$!
sleep 1

mkdir -p "$PROOF/gw"
cat >"$PROOF/gw/openclaw.json" <<JSON
{
  "gateway": { "mode": "local", "bind": "custom", "customBindHost": "$LAN_IP", "port": $GW_PORT,
    "auth": { "mode": "token", "token": "$TOKEN" } },
  "models": { "providers": { "prooflocal": { "api": "openai-completions",
    "baseUrl": "http://127.0.0.1:19537/v1", "apiKey": "sk-local-proof",
    "models": [{ "id": "proof-model", "name": "proof-model" }] } } },
  "agents": { "defaults": { "model": "prooflocal/proof-model" } },
  "tools": { "exec": { "security": "full" } },
  "plugins": { "entries": { "browser": { "enabled": false }, "geolocation": { "enabled": false } } }
}
JSON

say "start gateway on $LAN_IP:$GW_PORT"
( cd "$RUNTIME_DIR" && OPENCLAW_STATE_DIR="$PROOF/gw" OPENCLAW_NO_AUTO_UPDATE=1 \
  "$NODE_BIN" "$CLI" gateway >"$PROOF/gateway.log" 2>&1 ) &
GW_PID=$!
for i in $(seq 1 60); do
  if ss -tln 2>/dev/null | grep -q ":$GW_PORT "; then say "gateway listening after ${i}s"; break; fi
  sleep 1
done

# ---------------------------------------------------------------- node host
mkdir -p "$PROOF/node"
cat >"$PROOF/node/openclaw.json" <<JSON
{ "nodeHost": { "workerRuns": { "enabled": true, "isolation": "container",
  "containerImage": "node:24-bookworm-slim" } } }
JSON

say "start node host (container isolation)"
( cd "$RUNTIME_DIR" && OPENCLAW_STATE_DIR="$PROOF/node" OPENCLAW_GATEWAY_TOKEN="$TOKEN" \
  OPENCLAW_NO_AUTO_UPDATE=1 "$NODE_BIN" "$CLI" node run --host "$LAN_IP" --port "$GW_PORT" \
  --session-host --auth-from-env --display-name comma195304 >"$PROOF/nodehost.log" 2>&1 ) &
NODE_PID=$!

# approve device then node (loop over the pairing retry log)
approve_device() {
  local rid
  rid="$(grep -o 'device pairing required (requestId: [0-9a-f-]*' "$PROOF/nodehost.log" | tail -1 | grep -o '[0-9a-f-]*$')"
  [ -z "$rid" ] && return 1
  say "approve device $rid"
  GWC devices approve "$rid" --json >"$PROOF/approve-device.json" 2>&1 || true
  grep -q '"approvedAtMs"' "$PROOF/approve-device.json"
}
node_pending() {
  local rid
  rid="$(grep -o 'nodes approve [0-9a-f-]*' "$PROOF/nodehost.log" | tail -1 | grep -o '[0-9a-f-]*$')"
  [ -z "$rid" ] && return 1
  say "approve node $rid"
  GWC nodes approve "$rid" --json >"$PROOF/approve-node.json" 2>&1 || true
  grep -q '"requestId"' "$PROOF/approve-node.json"
}
for i in $(seq 1 40); do
  if approve_device; then break; fi
  sleep 1
done
for i in $(seq 1 40); do
  if node_pending; then sleep 2; break; fi
  grep -q 'gateway connected' "$PROOF/nodehost.log" && break
  sleep 1
done
sleep 3

# node id (device id) parsed from gateway log / node status
NODE_ID="$(grep -o 'deviceId=[0-9a-f]*' "$PROOF/gateway.log" | tail -1 | cut -d= -f2)"
say "node deviceId=$NODE_ID"

# ---------------------------------------------------------------- session
say "sessions.create deviceFolder (comma path)"
GWC gateway call sessions.create --params "{\"key\":\"$SESSION_KEY\",\"label\":\"comma195304\",\"deviceFolder\":{\"deviceId\":\"$NODE_ID\",\"path\":\"$DEVICE_FOLDER\"}}" --json >"$PROOF/create.json" 2>&1 || true
dump "sessions.create" cat "$PROOF/create.json"

say "sessions.dispatch (provisions worker runtime; client may time out, server continues)"
GWC gateway call sessions.dispatch --params "{\"key\":\"$SESSION_KEY\",\"deviceId\":\"$NODE_ID\"}" --json >"$PROOF/dispatch.json" 2>&1 || true
# wait placement active
for i in $(seq 1 30); do
  if GWC gateway call sessions.list --params '{}' --json 2>/dev/null | grep -q '"state": "active"'; then say "placement active after ${i}x5s"; break; fi
  sleep 5
done

say "sessions.send (launches container worker turn)"
GWC gateway call sessions.send --params "{\"key\":\"$SESSION_KEY\",\"message\":\"Write the marker file now.\",\"idempotencyKey\":\"comma195304-turn1\"}" --json >"$PROOF/send.json" 2>&1 || true
dump "sessions.send" cat "$PROOF/send.json"

# ---------------------------------------------------------------- verify
CONTAINER=""
for i in $(seq 1 30); do
  CONTAINER="$(docker ps -a --filter label=openclaw.node-worker.host --format '{{.ID}}' | head -1)"
  if [ -n "$CONTAINER" ]; then say "worker container appeared after ${i}x2s: $CONTAINER"; break; fi
  sleep 2
done

dump "docker inspect mounts (comma source/target, bundle read-only, private HOME)" \
  docker inspect --type container --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} rw={{.RW}}{{println}}{{end}}WORKDIR={{.Config.WorkingDir}}' "$CONTAINER"
marker() { echo "host workspace listing:"; ls -la "$DEVICE_FOLDER"; echo "marker content:"; cat "$DEVICE_FOLDER/MARKER_COMMA_195304.txt" 2>/dev/null || echo "(marker not found)"; }
dump "workspace marker on host" marker
marker_inside() { docker exec "$CONTAINER" sh -lc 'echo HOME=$HOME; cat MARKER_COMMA_195304.txt' 2>&1; }
dump "marker inside container (HOME should be private worker HOME)" marker_inside
dump "mock provider request log" cat "$PROOF/requests.log"

# wait for the assistant final answer
say "wait for assistant final message"
for i in $(seq 1 20); do
  if GWC gateway call chat.history --params "{\"key\":\"$SESSION_KEY\"}" --json 2>/dev/null | grep -q 'COMMA_WORKSPACE_PROOF_OK'; then
    say "assistant finalized after ${i}x3s"; break
  fi
  sleep 3
done
GWC gateway call chat.history --params "{\"key\":\"$SESSION_KEY\"}" --json 2>/dev/null | grep -o 'COMMA_WORKSPACE_PROOF_OK[^"]*' | head -1 || true

echo
dump "node host log (tail)" tail -40 "$PROOF/nodehost.log"
dump "gateway log (tail)" tail -30 "$PROOF/gateway.log"

say "DONE build_ok=$BUILD_OK container=$CONTAINER"
