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
MODEL_BASE_URL="${MODEL_BASE_URL:-https://maas-apigateway.dt.zte.com.cn/model-public/tokenplan/v1}"
MODEL_ID="${MODEL_ID:-glm-5.2}"

mkdir -p "$PROOF" "$DEVICE_FOLDER"
export PATH="$(dirname "$NODE_BIN"):$PATH"

# The startup launcher supplies NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt when
# it sees a version-manager runtime (NVM_DIR). Workers inherit it through the sandbox env
# allowlist and the container launch then refuses a CA file outside the admitted
# bundle/workspace. The model endpoint here is HTTPS with a public CA that the container
# already trusts, so no extra bundle is needed. OPENCLAW_NODE_EXTRA_CA_CERTS_READY pins that.
unset NVM_DIR
export OPENCLAW_NODE_EXTRA_CA_CERTS_READY=1
echo "[proof] NODE_EXTRA_CA_CERTS=${NODE_EXTRA_CA_CERTS:-<unset>} NVM_DIR=${NVM_DIR:-<unset>}"
rm -f "$PROOF/requests.log" "$PROOF/mock.log" "$PROOF/nodehost.log" "$PROOF/gateway.log"

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
GWCJ() { GWC gateway call "$1" --params "$2" --json --timeout "${3:-180000}" 2>&1; }

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
# Real model provider: the OpenAI-compatible endpoint is public (resolves to a public
# address from GitHub-hosted runners) and the key arrives as an encrypted repository
# secret. It is written to an owner-only file and never echoed.
if [ -z "${MODEL_API_KEY:-}" ]; then say "ABORT: MODEL_API_KEY is not set"; exit 1; fi
KEY_FILE="$PROOF/model-key"
( umask 077; printf '%s' "$MODEL_API_KEY" >"$KEY_FILE" )
chmod 600 "$KEY_FILE"
unset MODEL_API_KEY
say "provider: $MODEL_ID at $MODEL_BASE_URL (key from secret, 0600 file)"

mkdir -p "$PROOF/gw"
python3 - "$PROOF/gw/openclaw.json" "$LAN_IP" "$GW_PORT" "$TOKEN" "$KEY_FILE" "$MODEL_BASE_URL" "$MODEL_ID" <<'PY'
import json,sys
path,lan,port,token,keyfile,base,model=sys.argv[1:8]
key=open(keyfile).read().strip()
cfg={
 "gateway":{"mode":"local","bind":"custom","customBindHost":lan,"port":int(port),
   "auth":{"mode":"token","token":token},
   "nodes":{"pairing":{"autoApproveLocal":False}}},
 "models":{"providers":{"real":{"api":"openai-completions","baseUrl":base,"apiKey":key,
   "models":[{"id":model,"name":model,"contextWindow":1000000,"maxTokens":131072}]}}},
 "agents":{"defaults":{"model":"real/"+model}},
 "tools":{"exec":{"security":"full"}},
 "plugins":{"entries":{"browser":{"enabled":False},"geolocation":{"enabled":False}}},
}
json.dump(cfg,open(path,"w"),indent=2)
print("gateway config written (model=" + model + ")")
PY
rm -f "$KEY_FILE"

say "start gateway on $LAN_IP:$GW_PORT"
( cd "$RUNTIME_DIR" && OPENCLAW_STATE_DIR="$PROOF/gw" OPENCLAW_NO_AUTO_UPDATE=1 OPENCLAW_DEBUG=1 \
  "$NODE_BIN" "$CLI" gateway >"$PROOF/gateway.log" 2>&1 ) &
GW_PID=$!
for i in $(seq 1 150); do
  if ss -tln 2>/dev/null | grep -q ":$GW_PORT "; then say "gateway listening after ${i}s"; break; fi
  sleep 1
done
ss -tln 2>/dev/null | grep -q ":$GW_PORT " || { say "ABORT: gateway never listened"; tail -40 "$PROOF/gateway.log"; exit 1; }
dump "gateway models.list (real provider catalog)" GWCJ models.list '{}' 120000

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
# The first turn may fail while the worker runtime finishes installing; resend while the
# workspace marker stays absent so a transient launch rejection cannot mask the mount check.
for turn in 1 2 3; do
  GWCJ sessions.send "{\"key\":\"$SESSION_KEY\",\"message\":\"In your current working directory create the file MARKER_COMMA_195304.txt containing exactly the single line MARKER_COMMA_195304, then reply with COMMA_WORKSPACE_PROOF_OK. Do not ask questions.\",\"idempotencyKey\":\"comma195304-turn$turn\"}" >"$PROOF/send.$turn.json"
  dump "sessions.send (turn $turn)" cat "$PROOF/send.$turn.json"
  for i in $(seq 1 40); do
    [ -f "$DEVICE_FOLDER/MARKER_COMMA_195304.txt" ] && break
    sleep 3
  done
  [ -f "$DEVICE_FOLDER/MARKER_COMMA_195304.txt" ] && break
  say "turn $turn produced no workspace marker yet"
done

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
  dump "container argv/env/state" docker inspect --type container --format 'ARGS={{json .Args}}\nSTATE={{.State.Status}} exit={{.State.ExitCode}}\nHOME_ENV={{range .Config.Env}}{{if eq (slice . 0 4) "HOME"}}{{.}} {{end}}{{end}}' "$CONTAINER"
  dump "container filesystem workspace" docker exec "$CONTAINER" sh -lc 'pwd; ls -la; cat MARKER_COMMA_195304.txt' 2>&1 || true
  container_logs() { docker logs "$CONTAINER" 2>&1 | tail -30; }
  dump "docker logs (container)" container_logs
fi
marker() { echo "host workspace listing:"; ls -la "$DEVICE_FOLDER"; echo "marker content:"; cat "$DEVICE_FOLDER/MARKER_COMMA_195304.txt" 2>/dev/null || echo "(marker not found)"; }
dump "workspace marker on host" marker
if [ -n "$CONTAINER" ]; then
  marker_inside() { docker exec "$CONTAINER" sh -lc 'echo HOME=$HOME; cat MARKER_COMMA_195304.txt' 2>&1; }
  dump "marker inside container (HOME should be private worker HOME)" marker_inside
fi
dump "worker transcript (gateway llm call lines)" bash -c "grep -iE 'llm|provider|model|token usage|completion' '$PROOF/gateway.log' | tail -25"

say "wait for assistant final message"
FINAL=""
for i in $(seq 1 40); do
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

# A green workflow must mean the shipped flow worked, so the verdict drives the exit code.
MARKER_OK=0
[ -f "$DEVICE_FOLDER/MARKER_COMMA_195304.txt" ] && [ "$(cat "$DEVICE_FOLDER/MARKER_COMMA_195304.txt")" = "MARKER_COMMA_195304" ] && MARKER_OK=1
CONTAINER_OK=0
if [ -n "$CONTAINER" ]; then
  docker inspect --type container --format '{{range .Mounts}}{{.Source}}{{println}}{{end}}' "$CONTAINER" | grep -qF "$COMMA_ROOT" && CONTAINER_OK=1
fi
if [ "$BUILD_OK" = "1" ] && [ "$MARKER_OK" = "1" ] && [ "$CONTAINER_OK" = "1" ] && [ -n "$FINAL" ]; then
  say "VERDICT pass: real-model session wrote the marker through a container worker mounted from the comma path"
  exit 0
fi
say "VERDICT fail: build_ok=$BUILD_OK marker_ok=$MARKER_OK container_ok=$CONTAINER_OK final=${FINAL:-none}"
exit 1
