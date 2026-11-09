#!/usr/bin/env bash
# Shipped container-session proof for OpenClaw PR #195304.
# Runs on GitHub Actions ubuntu-latest (glibc >= 2.35, satisfies proc-safe's GLIBC_2.33+ need):
#   an isolated Gateway + node host complete a container-isolated session whose bundle,
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

# The hosted runner exports NODE_EXTRA_CA_CERTS for its own proxy. The worker inherits it
# through the sandbox environment allowlist, and the container launch then refuses a CA
# file outside the admitted bundle/workspace. Keep the runner's trust settings (the mock
# provider is plain http on loopback) and give the admitted workspace a copy so any host
# that still forwards the variable resolves it inside the mount.
if [ -n "${NODE_EXTRA_CA_CERTS:-}" ] && [ -f "$NODE_EXTRA_CA_CERTS" ]; then
  cp "$NODE_EXTRA_CA_CERTS" "$DEVICE_FOLDER/runner-ca.pem"
  export NODE_EXTRA_CA_CERTS="$DEVICE_FOLDER/runner-ca.pem"
  echo "[proof] runner CA relocated into the admitted workspace: $NODE_EXTRA_CA_CERTS"
else
  echo "[proof] runner CA: ${NODE_EXTRA_CA_CERTS:-<unset>}"
fi
rm -f "$PROOF/requests.log" "$PROOF/nodehost.log" "$PROOF/gateway.log"

say() { echo "[proof] $*"; }
head_step() { echo; echo "############ $* ############"; }
dump() { echo "===== $1 ====="; shift; "$@" 2>&1 | sed 's/^/  /' || true; echo; }

say "node=$($NODE_BIN -v) glibc=$(ldd --version 2>&1 | head -1) lan=$LAN_IP"
say "dockerd=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo MISSING)"

# ---------------------------------------------------------------- build or fallback
head_step "STAGE build"
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
import sys
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
GWCJ() { GWC gateway call "$1" --params "$2" --json 2>&1; }

cleanup() {
  say "cleanup: stopping background daemons"
  docker ps -aq --filter label=openclaw.node-worker.host | xargs -r docker rm -f >/dev/null 2>&1 || true
  kill "${NODE_PID:-}" "${GW_PID:-}" "${MOCK_PID:-}" 2>/dev/null || true
  sleep 1
  kill -9 "${NODE_PID:-}" "${GW_PID:-}" "${MOCK_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------- mock + gateway
head_step "STAGE gateway"
say "start mock provider"
"$NODE_BIN" "$SCRIPT_DIR/mock-provider.mjs" >"$PROOF/mock.log" 2>&1 &
MOCK_PID=$!
sleep 1

mkdir -p "$PROOF/gw"
cat >"$PROOF/gw/openclaw.json" <<JSON
{
  "gateway": { "mode": "local", "bind": "custom", "customBindHost": "$LAN_IP", "port": $GW_PORT,
    "auth": { "mode": "token", "token": "$TOKEN" },
    "nodes": { "pairing": { "autoApproveLocal": false } } },
  "models": { "providers": { "prooflocal": { "api": "openai-completions",
    "baseUrl": "http://127.0.0.1:19537/v1", "apiKey": "sk-local-proof",
    "models": [{ "id": "proof-model", "name": "proof-model" }] } } },
  "agents": { "defaults": { "model": "prooflocal/proof-model" } },
  "tools": { "exec": { "security": "full" } },
  "plugins": { "entries": { "browser": { "enabled": false }, "geolocation": { "enabled": false } } }
}
JSON

say "start gateway on $LAN_IP:$GW_PORT"
( cd "$RUNTIME_DIR" && OPENCLAW_STATE_DIR="$PROOF/gw" OPENCLAW_NO_AUTO_UPDATE=1 OPENCLAW_DEBUG=1 \
  "$NODE_BIN" "$CLI" gateway >"$PROOF/gateway.log" 2>&1 ) &
GW_PID=$!
for i in $(seq 1 90); do
  if ss -tln 2>/dev/null | grep -q ":$GW_PORT "; then say "gateway listening after ${i}s"; break; fi
  sleep 1
done

# ---------------------------------------------------------------- node host
head_step "STAGE node host"
mkdir -p "$PROOF/node"
# deviceFolders capability is node-local consent: it is only advertised when the
# node's own config enumerates worker folder roots, so the comma-bearing demo root
# has to appear here too.
cat >"$PROOF/node/openclaw.json" <<JSON
{ "nodeHost": { "workerRuns": { "enabled": true, "isolation": "container",
  "containerImage": "node:24-bookworm-slim", "folders": ["$COMMA_ROOT"] } } }
JSON
dump "node host config" cat "$PROOF/node/openclaw.json"

start_node_host() {
  ( cd "$RUNTIME_DIR" && OPENCLAW_STATE_DIR="$PROOF/node" OPENCLAW_GATEWAY_TOKEN="$TOKEN" \
    OPENCLAW_NO_AUTO_UPDATE=1 "$NODE_BIN" "$CLI" node run --host "$LAN_IP" --port "$GW_PORT" \
    --session-host --auth-from-env --display-name comma195304 ) >"$PROOF/nodehost.log" 2>&1 &
  NODE_PID=$!
}

approve_device() {
  local rid
  rid="$(grep -o 'device pairing required (requestId: [0-9a-f-]*' "$PROOF/nodehost.log" | tail -1 | grep -o '[0-9a-f-]*$')"
  [ -z "$rid" ] && return 1
  say "approve device $rid"
  GWC devices approve "$rid" --json >"$PROOF/approve-device.json" 2>&1 || true
  dump "devices approve" cat "$PROOF/approve-device.json"
  grep -q '"approvedAtMs"' "$PROOF/approve-device.json"
}

node_pending_id() {
  grep -o 'nodes approve [0-9a-f-]*' "$PROOF/nodehost.log" | tail -1 | grep -o '[0-9a-f-]*$'
}

# Does this session enumerate the node's worker host surface with device folders?
worker_host_ready() {
  GWCJ node.list '{}' | python3 -c '
import json,sys
try: data=json.load(sys.stdin)
except Exception: sys.exit(1)
body=data.get("result") if isinstance(data,dict) else None
body=body if isinstance(body,dict) else data
nodes=body.get("nodes") if isinstance(body,dict) else None
for n in nodes or []:
    wh=n.get("workerHost") or {}
    # node.list projects only consent-gated fields; enabled:true appears on the
    # richer inventory record, so accept either shape.
    if wh.get("deviceFolders") is True and wh.get("enabled") is not False:
        print(n.get("nodeId"), json.dumps(wh))
        sys.exit(0)
sys.exit(1)
'
}

: >"$PROOF/nodehost.log"
start_node_host
APPROVED_DEVICE=0
for i in $(seq 1 60); do
  if approve_device; then APPROVED_DEVICE=1; break; fi
  sleep 1
done
say "device approved=$APPROVED_DEVICE"

NODE_RID=""
for i in $(seq 1 60); do
  NODE_RID="$(node_pending_id)"
  [ -n "$NODE_RID" ] && break
  grep -q 'gateway connected' "$PROOF/nodehost.log" && break
  sleep 1
done
say "node surface requestId=${NODE_RID:-none}"
if [ -n "$NODE_RID" ]; then
  GWC nodes approve "$NODE_RID" --json >"$PROOF/approve-node.json" 2>&1 || true
  dump "nodes approve" cat "$PROOF/approve-node.json"
fi

# The node republishes inventory after approval; if it cannot, restart it onto the
# already-approved identity instead of waiting on a retry that will not arrive.
READY=0
SURFACE_INFO=""
surface_shape() {
  GWCJ node.list '{}' >"$PROOF/node.list.json" 2>"$PROOF/node.list.err" || true
  python3 - "$PROOF/node.list.json" <<'PY'
import json,sys
try:
    data=json.load(open(sys.argv[1]))
except Exception as exc:
    print("  node.list unparsable:", exc); raise SystemExit
body=data.get("result") if isinstance(data,dict) else None
body=body if isinstance(body,dict) else data
nodes=body.get("nodes") if isinstance(body,dict) else None
print("  node.list keys:", sorted(body) if isinstance(body,dict) else type(body).__name__)
for n in nodes or []:
    print("  node", n.get("nodeId"), "connected=", n.get("connected"), "status=", n.get("status"),
          "workerHost=", json.dumps(n.get("workerHost")), "keys=", sorted(n))
PY
  echo "  -- node host worker/hosting lines --"
  grep -E 'worker|hosting|runner|inventory|disabled|capabilit|hello' "$PROOF/nodehost.log" | tail -25 || true
}
for i in $(seq 1 24); do
  if SURFACE_INFO="$(worker_host_ready)"; then READY=1; say "worker host ready after ${i}x5s: $SURFACE_INFO"; break; fi
  say "attempt $i: worker host not published yet"
  if [ "$i" = "1" ] || [ $((i % 6)) -eq 0 ]; then dump "surface shape (attempt $i)" surface_shape; fi
  sleep 5
  if [ $((i % 6)) -eq 0 ]; then
    say "restarting node host onto its approved identity"
    kill "$NODE_PID" 2>/dev/null || true
    sleep 2
    kill -9 "$NODE_PID" 2>/dev/null || true
    cp "$PROOF/nodehost.log" "$PROOF/nodehost.attempt$i.log"
    : >"$PROOF/nodehost.log"
    start_node_host
    for j in $(seq 1 30); do
      NODE_RID="$(node_pending_id)"
      [ -n "$NODE_RID" ] && break
      sleep 1
    done
    if [ -n "$NODE_RID" ]; then GWC nodes approve "$NODE_RID" --json >"$PROOF/approve-node.json" 2>&1 || true; fi
  fi
done
diagnose_nodehost() {
  echo "-- full node host log --"
  tail -120 "$PROOF/nodehost.log"
  echo "-- archived attempts --"
  for f in "$PROOF"/nodehost.attempt*.log; do
    [ -f "$f" ] || continue
    echo "== $f =="
    tail -20 "$f"
  done
  echo "-- gateway worker/hosting lines --"
  grep -E 'worker|hosting|runner|inventory' "$PROOF/gateway.log" | tail -40 || true
}
dump "node host diagnostics" diagnose_nodehost
if [ "$READY" != "1" ]; then say "ABORT: node host never published its worker surface"; exit 1; fi

NODE_ID="$(echo "$SURFACE_INFO" | awk '{print $1}')"
say "node deviceId=$NODE_ID"

# ---------------------------------------------------------------- session
head_step "STAGE session"
say "sessions.create deviceFolder (comma path)"
GWCJ sessions.create "{\"key\":\"$SESSION_KEY\",\"label\":\"comma195304\",\"deviceFolder\":{\"deviceId\":\"$NODE_ID\",\"path\":\"$DEVICE_FOLDER\"}}" >"$PROOF/create.json"
dump "sessions.create" cat "$PROOF/create.json"

say "sessions.dispatch (provisions worker runtime; client may time out, server continues)"
GWCJ sessions.dispatch "{\"key\":\"$SESSION_KEY\",\"deviceId\":\"$NODE_ID\"}" >"$PROOF/dispatch.json"
dump "sessions.dispatch" cat "$PROOF/dispatch.json"
for i in $(seq 1 30); do
  if GWCJ sessions.list '{}' | grep -q '"state": "active"'; then say "placement active after ${i}x5s"; break; fi
  sleep 5
done

say "sessions.send (launches container worker turn)"
GWCJ sessions.send "{\"key\":\"$SESSION_KEY\",\"message\":\"Write the marker file now.\",\"idempotencyKey\":\"comma195304-turn1\"}" >"$PROOF/send.json"
dump "sessions.send" cat "$PROOF/send.json"

# ---------------------------------------------------------------- verify
head_step "STAGE verify"
CONTAINER=""
for i in $(seq 1 45); do
  CONTAINER="$(docker ps -a --filter label=openclaw.node-worker.host --format '{{.ID}}' | head -1)"
  if [ -n "$CONTAINER" ]; then say "worker container appeared after ${i}x2s: $CONTAINER"; break; fi
  sleep 2
done

if [ -n "$CONTAINER" ]; then
  dump "docker inspect mounts (comma source/target, bundle read-only, private HOME)" \
    docker inspect --type container --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} rw={{.RW}}{{println}}{{end}}WORKDIR={{.Config.WorkingDir}}' "$CONTAINER"
fi
marker() { echo "host workspace listing:"; ls -la "$DEVICE_FOLDER"; echo "marker content:"; cat "$DEVICE_FOLDER/MARKER_COMMA_195304.txt" 2>/dev/null || echo "(marker not found)"; }
dump "workspace marker on host" marker
if [ -n "$CONTAINER" ]; then
  marker_inside() { docker exec "$CONTAINER" sh -lc 'echo HOME=$HOME; cat MARKER_COMMA_195304.txt' 2>&1; }
  dump "marker inside container (HOME should be private worker HOME)" marker_inside
fi
dump "mock provider request log" cat "$PROOF/requests.log"

say "wait for assistant final message"
FINAL=""
for i in $(seq 1 20); do
  FINAL="$(GWCJ chat.history "{\"sessionKey\":\"$SESSION_KEY\"}" | grep -o 'COMMA_WORKSPACE_PROOF_OK[^"]*' | head -1)"
  if [ -n "$FINAL" ]; then say "assistant finalized after ${i}x3s"; break; fi
  sleep 3
done
GWCJ chat.history "{\"sessionKey\":\"$SESSION_KEY\"}" >"$PROOF/history.json"
dump "chat history (tail)" tail -40 "$PROOF/history.json"

head_step "STAGE logs"
diag_all() {
  echo "-- node host (worker/container lines) --"
  grep -E 'worker|runner|inventory|docker|container|launch|bundle|workspace|error|failed' "$PROOF/nodehost.log" | tail -60
  echo "-- gateway (worker/container lines) --"
  grep -E 'worker|container|launch|provision|admission|invalid field|mount|error|failed|stale' "$PROOF/gateway.log" | tail -60
}
dump "diagnostics" diag_all

say "DONE build_ok=$BUILD_OK container=$CONTAINER final=$FINAL"
