#!/usr/bin/env bash
set -euo pipefail

# Runs inside a guest booted from the golden base image (which has all
# dependencies and product binaries baked in). It installs the agent binary,
# writes the static parking-time environment, starts services, and performs
# Moonlight pairing.

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    printf 'Required environment variable missing: %s\n' "$name" >&2
    exit 1
  fi
}

require_env MACHINE_NAME
require_env MACHINE_IP
require_env AGENT_SERVER_TAG

MACHINE_SUBDOMAIN="${MACHINE_SUBDOMAIN:-$MACHINE_NAME}"
INSTALL_DIR="${INSTALL_DIR:-/opt/ascii-agent}"
RESULT_FILE="${RESULT_FILE:-$INSTALL_DIR/provision-result.env}"
AGENT_PORT="${AGENT_PORT:-8911}"
BACKEND_URL="${BACKEND_URL:-https://ascii.dev}"
BOX_CLI_API_URL="${BOX_CLI_API_URL:-$BACKEND_URL}"
BOX_CLI_CHANNEL="${BOX_CLI_CHANNEL:-prod}"
BOX_CLI_MODE="${BOX_CLI_MODE:-box}"
BOX_CLI_TAG="${BOX_CLI_TAG:-}"
AGENTS_SERVER_CHANNEL="${AGENTS_SERVER_CHANNEL:-}"
ENABLE_AGENT_V6_PROXY="${ENABLE_AGENT_V6_PROXY:-1}"
# IPv4 doorway (bare-metal): v4-only clients reach WebRTC through the node's
# public IPv4 + a per-VM DNATed UDP block. When set, the streamer binds that
# block and advertises the node's v4 alongside the guest's v6.
NODE_PUBLIC_IPV4="${NODE_PUBLIC_IPV4:-}"
WEBRTC_PORT_MIN="${WEBRTC_PORT_MIN:-49152}"
WEBRTC_PORT_MAX="${WEBRTC_PORT_MAX:-65535}"
SHARED_KEY="${SHARED_KEY:-$(openssl rand -hex 32)}"

log() {
  printf '[guest-runtime-setup] %s\n' "$*"
}

log "runtime setup for $MACHINE_NAME ($MACHINE_IP)"

if [ "$ENABLE_AGENT_V6_PROXY" = "1" ]; then
  command -v socat >/dev/null || { echo 'golden image is missing socat' >&2; exit 1; }
fi
command -v codex >/dev/null || { echo 'golden image is missing pinned Codex CLI' >&2; exit 1; }

IMAGE_ASSET_DIR=/opt/ascii-image-assets
IMAGE_ASSET_MANIFEST="$IMAGE_ASSET_DIR/manifest.json"
[ -f "$IMAGE_ASSET_MANIFEST" ] || { echo 'golden image platform manifest is missing' >&2; exit 1; }
[[ "$AGENT_SERVER_TAG" =~ ^agent-server-v[A-Za-z0-9._-]+$ ]] || { echo 'AGENT_SERVER_TAG must pin an agent-server-v* release' >&2; exit 1; }
image_agent_tag="$(jq -er '.agentServer.tag' "$IMAGE_ASSET_MANIFEST")"
expected_agent_sha="$(jq -er '.agentServer.sha256' "$IMAGE_ASSET_MANIFEST")"
[ "$image_agent_tag" = "$AGENT_SERVER_TAG" ] || { echo "image agent tag $image_agent_tag does not match $AGENT_SERVER_TAG" >&2; exit 1; }
[[ "$expected_agent_sha" =~ ^[a-f0-9]{64}$ ]] || { echo 'invalid baked agent checksum' >&2; exit 1; }
printf '%s  %s\n' "$expected_agent_sha" "$IMAGE_ASSET_DIR/ascii-agents-server" | sha256sum -c -

log "installing agent-server $AGENT_SERVER_TAG from the immutable golden image"
mkdir -p "$INSTALL_DIR"
install -m 0755 "$IMAGE_ASSET_DIR/ascii-agents-server" "$INSTALL_DIR/ascii-agents-server"
chown -R user:user "$INSTALL_DIR"

mkdir -p /home/user/.ssh
chmod 700 /home/user/.ssh
chown user:user /home/user/.ssh

cat > /etc/systemd/system/ascii-agent.service <<SERVICEEOF
[Unit]
Description=Ascii Agent Server
After=network-online.target ariana-fswatch.service
Wants=network-online.target ariana-fswatch.service

[Service]
Type=simple
User=user
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/ascii-agents-server
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

if [ "$ENABLE_AGENT_V6_PROXY" = "1" ]; then
  cat > /etc/systemd/system/ascii-agent-v6-proxy.service <<SERVICEEOF
[Unit]
Description=IPv6 proxy for Ascii Agent Server
After=ascii-agent.service
Wants=ascii-agent.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP6-LISTEN:$AGENT_PORT,fork,reuseaddr,ipv6only=1 TCP4:127.0.0.1:$AGENT_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICEEOF
else
  rm -f /etc/systemd/system/ascii-agent-v6-proxy.service
fi

log "using Codex CLI baked into the golden image: $(codex --version)"

log "installing Box CLI $BOX_CLI_TAG from the immutable golden image"
BOX_CLI_BIN_DIR="/home/user/.ascii/bin"
BOX_CLI_CONFIG_DIR="/home/user/.config/ascii/$BOX_CLI_MODE"
[[ "$BOX_CLI_TAG" =~ ^box-cli-v[A-Za-z0-9._-]+$ ]] || { echo "BOX_CLI_TAG must pin a box-cli-v* release" >&2; exit 1; }
image_box_tag="$(jq -er '.boxCli.tag' "$IMAGE_ASSET_MANIFEST")"
expected_box_sha="$(jq -er '.boxCli.sha256' "$IMAGE_ASSET_MANIFEST")"
[ "$image_box_tag" = "$BOX_CLI_TAG" ] || { echo "image Box CLI tag $image_box_tag does not match $BOX_CLI_TAG" >&2; exit 1; }
[[ "$expected_box_sha" =~ ^[a-f0-9]{64}$ ]] || { echo 'invalid baked Box CLI checksum' >&2; exit 1; }
printf '%s  %s\n' "$expected_box_sha" "$IMAGE_ASSET_DIR/box" | sha256sum -c -
mkdir -p "$BOX_CLI_BIN_DIR" "$BOX_CLI_CONFIG_DIR"
install -m 0755 "$IMAGE_ASSET_DIR/box" "$BOX_CLI_BIN_DIR/$BOX_CLI_MODE"
ln -sf "$BOX_CLI_BIN_DIR/$BOX_CLI_MODE" "/usr/local/bin/$BOX_CLI_MODE"
cat > "$BOX_CLI_CONFIG_DIR/config.json" <<BOXCLICONFIG
{
  "api_url": "$BOX_CLI_API_URL",
  "channel": "$BOX_CLI_CHANNEL"
}
BOXCLICONFIG
chown -R user:user /home/user/.ascii /home/user/.config/ascii

log "writing agent env"
cat > "$INSTALL_DIR/.env" <<ENVEOF
MACHINE_ID=$MACHINE_NAME
SHARED_KEY=$SHARED_KEY
WORK_DIR=/home/user
BACKEND_URL=$BACKEND_URL
BOX_CLI_API_URL=$BOX_CLI_API_URL
BOX_CLI_CHANNEL=$BOX_CLI_CHANNEL
BOX_CLI_MODE=$BOX_CLI_MODE
BOX_CLI_TAG=$BOX_CLI_TAG
AGENTS_SERVER_CHANNEL=$AGENTS_SERVER_CHANNEL
ASCII_PORT=$AGENT_PORT
CLAUDE_PATH=/usr/local/bin/claude
CODEX_PATH=/usr/local/bin/codex
IS_SANDBOX=1
MACHINE_SUBDOMAIN=$MACHINE_SUBDOMAIN
MACHINE_IP=$MACHINE_IP
ENVEOF
chmod 600 "$INSTALL_DIR/.env"
chown -R user:user "$INSTALL_DIR"

touch /home/user/.base-image-timestamp
chown user:user /home/user/.base-image-timestamp
dpkg --get-selections | grep -v deinstall | cut -f1 | sort > /home/user/.base-apt-packages.txt
chown user:user /home/user/.base-apt-packages.txt
if command -v snap >/dev/null 2>&1; then
  snap list | tail -n +2 | awk '{print $1}' | sort > /home/user/.base-snap-packages.txt || true
  chown user:user /home/user/.base-snap-packages.txt 2>/dev/null || true
fi

log "starting ascii-agent and fswatch"
systemctl daemon-reload
systemctl enable ariana-fswatch.service ascii-agent.service
systemctl restart ariana-fswatch.service
systemctl restart ascii-agent.service
if [ "$ENABLE_AGENT_V6_PROXY" = "1" ]; then
  systemctl enable ascii-agent-v6-proxy.service
  systemctl restart ascii-agent-v6-proxy.service
fi

log "initializing desktop and streaming"
systemctl restart lightdm
sleep 5

XAUTH_FILE="$(find /var/run/lightdm -name "*:0" 2>/dev/null | head -1 || true)"
if [ -n "$XAUTH_FILE" ]; then
  cp "$XAUTH_FILE" /home/user/.Xauthority
  chown user:user /home/user/.Xauthority
  chmod 600 /home/user/.Xauthority
fi

pkill -9 gnome-screensaver 2>/dev/null || true
pkill -f light-locker 2>/dev/null || true
loginctl unlock-sessions 2>/dev/null || true
sudo -u user DISPLAY=:0 xset s off 2>/dev/null || true
sudo -u user DISPLAY=:0 xset -dpms 2>/dev/null || true
sudo -u user DISPLAY=:0 xset s noblank 2>/dev/null || true
sudo -u user DISPLAY=:0 pulseaudio --start --exit-idle-time=-1 2>/dev/null || true
sleep 1

mkdir -p /home/user/.config/sunshine
if [ ! -f /home/user/.config/sunshine/sunshine.key ]; then
  openssl req -x509 -newkey rsa:4096 -keyout /home/user/.config/sunshine/sunshine.key \
    -out /home/user/.config/sunshine/sunshine.cert -days 3650 -nodes \
    -subj "/CN=sunshine" 2>/dev/null
fi
chown -R user:user /home/user/.config/sunshine
chmod 600 /home/user/.config/sunshine/*.key 2>/dev/null || true
sudo -u user HOME=/home/user sunshine --creds user user 2>&1 || true

MOONLIGHT_DIR="/opt/moonlight-web"
ADMIN_PASSWORD="$(openssl rand -hex 16)"
NAT_1TO1_IPS_JSON="\"$MACHINE_IP\""
if [ -n "$NODE_PUBLIC_IPV4" ]; then
  NAT_1TO1_IPS_JSON="$NAT_1TO1_IPS_JSON, \"$NODE_PUBLIC_IPV4\""
fi
cat > "$MOONLIGHT_DIR/server/config.json" <<MLCONF
{
    "data_storage": {
        "type": "json",
        "path": "$MOONLIGHT_DIR/server/data.json",
        "session_expiration_check_interval": {"secs": 300, "nanos": 0}
    },
    "web_server": {
        "bind_address": "[::1]:8090",
        "first_login_create_admin": true,
        "first_login_assign_global_hosts": true,
        "session_cookie_expiration": {"secs": 31536000, "nanos": 0}
    },
    "webrtc": {
        "ice_servers": [
            {"urls": ["stun:stun.l.google.com:19302"]}
        ],
        "port_range": {"min": $WEBRTC_PORT_MIN, "max": $WEBRTC_PORT_MAX},
        "nat_1to1": {
            "ips": [$NAT_1TO1_IPS_JSON],
            "ice_candidate_type": "host"
        },
        "include_loopback_candidates": false
    },
    "moonlight": {"default_http_port": 47989},
    "streamer_path": "$MOONLIGHT_DIR/streamer"
}
MLCONF
cat > "$MOONLIGHT_DIR/server/data.json" <<'STORCONF'
{"version": "2", "users": {}, "hosts": {}}
STORCONF
chown -R user:user "$MOONLIGHT_DIR"

pkill -f sunshine 2>/dev/null || true
sleep 2
for _ in $(seq 1 10); do
  if DISPLAY=:0 xset q >/dev/null 2>&1; then break; fi
  sleep 1
done
rm -f /tmp/sunshine.log
sudo -u user HOME=/home/user DISPLAY=:0 XAUTHORITY=/home/user/.Xauthority \
  sh -c 'exec nohup sunshine > /tmp/sunshine.log 2>&1' &
sleep 5

systemctl daemon-reload
systemctl enable sunshine moonlight-web xdotool-server
systemctl restart moonlight-web xdotool-server
sleep 3

MOONLIGHT_BASE="http://[::1]:8090"
for _ in $(seq 1 20); do
  if curl -g -s "$MOONLIGHT_BASE/" >/dev/null 2>&1; then break; fi
  sleep 1
done

LOGIN_RESPONSE="$(curl -g -s -i -X POST "$MOONLIGHT_BASE/api/login" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}" 2>&1)"
SESSION_TOKEN="$(printf '%s\n' "$LOGIN_RESPONSE" | grep -i 'set-cookie.*mlSession' | sed 's/.*mlSession=\([^;]*\).*/\1/' | tr -d '\r\n' || true)"

for _ in $(seq 1 10); do
  if curl -s -k -u "user:user" "https://127.0.0.1:47990/api/apps" --connect-timeout 2 2>&1 | grep -q "apps\|env"; then break; fi
  sleep 2
done

ADD_RESPONSE="$(curl -g -s -X POST "$MOONLIGHT_BASE/api/host" \
  -H "Content-Type: application/json" \
  -H "Cookie: mlSession=$SESSION_TOKEN" \
  -d '{"address":"127.0.0.1","http_port":47989}' 2>&1)"
HOST_ID="$(printf '%s\n' "$ADD_RESPONSE" | grep -o '"host_id":[0-9]*' | head -1 | cut -d: -f2 || true)"

PAIRING_SUCCESS=false
if [ -n "$HOST_ID" ]; then
  for _ in 1 2 3; do
    PAIR_OUTPUT="/tmp/moonlight-pair-$$"
    rm -f "$PAIR_OUTPUT"
    curl -g -s -N -X POST "$MOONLIGHT_BASE/api/pair" \
      -H "Content-Type: application/json" \
      -H "Cookie: mlSession=$SESSION_TOKEN" \
      -d "{\"host_id\":$HOST_ID}" > "$PAIR_OUTPUT" 2>&1 &
    CURL_PID=$!
    PIN=""
    for _ in $(seq 1 30); do
      if [ -s "$PAIR_OUTPUT" ]; then
        FIRST_LINE="$(head -1 "$PAIR_OUTPUT" 2>/dev/null || true)"
        PIN="$(printf '%s\n' "$FIRST_LINE" | grep -oE '"Pin":"[0-9]+"' | cut -d'"' -f4 || true)"
        [ -z "$PIN" ] && PIN="$(printf '%s\n' "$FIRST_LINE" | grep -oE '[0-9]{4}' | head -1 || true)"
        [ -n "$PIN" ] && break
      fi
      sleep 0.5
    done
    if [ -n "$PIN" ]; then
      curl -s -k -u "user:user" -X POST "https://127.0.0.1:47990/api/pin" \
        -H "Content-Type: application/json" \
        -d "{\"pin\":\"$PIN\",\"name\":\"moonlight-web\"}" \
        --connect-timeout 5 --max-time 10 >/dev/null 2>&1 || true
    fi
    for _ in $(seq 1 20); do
      kill -0 "$CURL_PID" 2>/dev/null || break
      sleep 0.5
    done
    kill "$CURL_PID" 2>/dev/null || true
    wait "$CURL_PID" 2>/dev/null || true
    PAIR_RESULT="$(cat "$PAIR_OUTPUT" 2>/dev/null || true)"
    rm -f "$PAIR_OUTPUT"
    if printf '%s\n' "$PAIR_RESULT" | grep -q "Paired"; then
      PAIRING_SUCCESS=true
      break
    fi
    HOST_STATUS="$(curl -g -s "$MOONLIGHT_BASE/api/host?host_id=$HOST_ID" -H "Cookie: mlSession=$SESSION_TOKEN" 2>&1 || true)"
    if printf '%s\n' "$HOST_STATUS" | grep -q '"paired":"Paired"'; then
      PAIRING_SUCCESS=true
      break
    fi
    sleep 2
  done
fi

APP_ID=""
if [ -n "$HOST_ID" ]; then
  APPS_RESPONSE="$(curl -g -s "$MOONLIGHT_BASE/api/apps?host_id=$HOST_ID" -H "Cookie: mlSession=$SESSION_TOKEN" 2>&1 || true)"
  APP_ID="$(printf '%s\n' "$APPS_RESPONSE" | grep -o '"app_id":[0-9]*' | head -1 | cut -d: -f2 || true)"
  [ -z "$APP_ID" ] && APP_ID="881448767"
fi

# SECURITY: the whole bootstrap above ran moonlight-web bound to loopback
# ([::1]:8090) on purpose. moonlight-web starts with an empty user DB and
# first_login_create_admin=true, so between its start and the admin login above
# it will make an ADMIN out of whoever logs in first. bind_address used to be
# [::]:8090 (all interfaces) during that window, so an outsider who reached
# :8090 on the public interface during provisioning — before this box is ever
# assigned to a customer — could win that first login, gain full desktop
# (screen + xdotool keyboard/mouse) control, and plant OS-level persistence that
# survives into whoever the box is later handed to. Binding to loopback for the
# bootstrap makes that window unreachable off-box. Now that a real admin exists
# (first_login can no longer fire), flip the bind to all interfaces for the
# gateway and refresh the session token against the re-exposed instance.
sed -i 's#"bind_address": "\[::1\]:8090"#"bind_address": "[::]:8090"#' "$MOONLIGHT_DIR/server/config.json"
systemctl restart moonlight-web
for _ in $(seq 1 20); do
  if curl -g -s "$MOONLIGHT_BASE/" >/dev/null 2>&1; then break; fi
  sleep 1
done
RELOGIN_RESPONSE="$(curl -g -s -i -X POST "$MOONLIGHT_BASE/api/login" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}" 2>&1)"
REFRESHED_TOKEN="$(printf '%s\n' "$RELOGIN_RESPONSE" | grep -i 'set-cookie.*mlSession' | sed 's/.*mlSession=\([^;]*\).*/\1/' | tr -d '\r\n' || true)"
[ -n "$REFRESHED_TOKEN" ] && SESSION_TOKEN="$REFRESHED_TOKEN"

cat > "$MOONLIGHT_DIR/server/streaming-credentials.json" <<CREDEOF
{
  "hostId": ${HOST_ID:-0},
  "appId": ${APP_ID:-881448767},
  "token": "$SESSION_TOKEN",
  "xdotoolPort": 9091
}
CREDEOF
echo "$SESSION_TOKEN" > "$MOONLIGHT_DIR/session.token"
echo "$ADMIN_PASSWORD" > "$MOONLIGHT_DIR/admin.password"
echo "$HOST_ID" > "$MOONLIGHT_DIR/host.id"
echo "$APP_ID" > "$MOONLIGHT_DIR/app.id"
chmod 600 "$MOONLIGHT_DIR/session.token" "$MOONLIGHT_DIR/admin.password"
chown -R user:user "$MOONLIGHT_DIR"

pkill -f gnome-screensaver 2>/dev/null || true
loginctl unlock-sessions 2>/dev/null || true

# --- fswatch baseline: drop provision churn from the pending sets ------------
# Provisioning touches ~100k paths under /; without a drain the system watcher
# carries a ~10MB pending set for the machine's whole parked life. A parked
# machine's first real snapshot is a full base regardless, so the pending list
# holds nothing of value -- wipe it. The system and docker sockets are created
# by the agent-server shortly after it starts; wait briefly for each and skip
# (non-fatal, capture stays correct via events_lost/base) if one never appears.
log "baselining fswatch daemons (drop provision churn)"
for sock in /run/ariana-fswatch.sock /run/ariana-fswatch-system.sock /run/ariana-fswatch-docker.sock; do
  for _ in $(seq 1 30); do [ -S "$sock" ] && break; sleep 2; done
  if [ -S "$sock" ]; then
    resp="$(printf '{"op":"baseline"}\n' | socat -t 10 - "UNIX-CONNECT:$sock" 2>&1 || true)"
    log "baseline $sock -> ${resp:-no-response}"
  else
    log "baseline $sock skipped (socket never appeared)"
  fi
done

# --- TRIM: hand freed blocks back to the host qcow2 ---------------------------
# The VM disk is attached with discard=unmap (provision-vm.sh); fstrim turns
# guest-side freed blocks into hole punches in the host overlay. Ubuntu's
# default weekly fstrim.timer is too slow for a pool -- run daily, plus once
# now to return the provisioning churn immediately.
log "enabling daily fstrim"
mkdir -p /etc/systemd/system/fstrim.timer.d
cat > /etc/systemd/system/fstrim.timer.d/daily.conf <<'FSTRIMEOF'
[Timer]
OnCalendar=
OnCalendar=daily
FSTRIMEOF
systemctl daemon-reload
systemctl enable --now fstrim.timer
fstrim -av || log "fstrim returned nonzero (discard not enabled on this VM?)"

cat > "$RESULT_FILE" <<RESULTEOF
SHARED_KEY=$SHARED_KEY
STREAMING_TOKEN=$SESSION_TOKEN
STREAMING_HOST_ID=${HOST_ID:-}
STREAMING_APP_ID=${APP_ID:-}
PAIRING_SUCCESS=$PAIRING_SUCCESS
RESULTEOF
chmod 600 "$RESULT_FILE"
chown user:user "$RESULT_FILE"

# --- base-image contract (ASC-288): stamp provision-COMPLETE state as "base" --
# Hetzner machines get both of these from the park step over root SSH
# (machinePool.service regenerates the /home/user manifest and writes the
# pristine system baseline after ALL provisioning). Root SSH is revoked on
# bare-metal guests (ASC-187), so the guest does it itself, HERE, after the
# last provisioning write. This is what makes snapshots port across providers:
# everything provisioning added (agent binary, moonlight creds, SHARED_KEY) is
# "base", so captures skip it and restores keep the DESTINATION machine's
# copies. Anything written below this block would instead be captured into
# every box's snapshots — including per-machine secrets. Do not add writes
# after it.
log "regenerating base-image manifest (provision-complete /home/user state)"
if [ -x /usr/local/lib/ascii/generate-base-image-manifest.py ]; then
  python3 /usr/local/lib/ascii/generate-base-image-manifest.py
  chown user:user /home/user/.base-image-manifest.json /home/user/.base-image-version
else
  log "generator missing (pre-ASC-288 image): keeping the Packer-time manifest"
fi
log "writing pristine system baseline"
if ! "$INSTALL_DIR/ascii-agents-server" write-system-baseline; then
  log "agent-server lacks write-system-baseline (pre-ASC-288 build): system roots stay event-sourced"
fi

echo "SHARED_KEY_PRESENT=yes"
echo "STREAMING_TOKEN_PRESENT=$([ -n "$SESSION_TOKEN" ] && echo yes || echo no)"
echo "STREAMING_HOST_ID=${HOST_ID:-}"
echo "STREAMING_APP_ID=${APP_ID:-}"
echo "PAIRING_SUCCESS=$PAIRING_SUCCESS"
echo "runtime-setup-complete"
