#!/bin/sh
# Scripts/run-bridge-demo.sh
#
# Starts a chatview-acp-bridge in front of the scripted fake agent, and prints the transport
# config to paste into a demo. This is the one command that turns "a phone can drive a remote
# agent" from a claim into something you can hold.
#
#   ./Scripts/run-bridge-demo.sh              # loopback only (simulator, same Mac)
#   ./Scripts/run-bridge-demo.sh --lan        # also reachable from a real iPhone on the LAN
#
# Ctrl-C stops the bridge and its agent.

set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
listen_host="127.0.0.1"
port="8737"
demo_dir="$repo_root/.build/bridge-demo"

while [ $# -gt 0 ]; do
    case "$1" in
    --lan)
        # A real device cannot reach the Mac's loopback. Bind the LAN address instead - the
        # client's own scheme policy allows cleartext ws:// to RFC 1918, so this works without
        # TLS on a trusted network and nowhere else.
        listen_host=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")
        if [ -z "$listen_host" ]; then
            printf '%s\n' "run-bridge-demo: could not find a LAN address on en0 or en1" 1>&2
            exit 1
        fi
        ;;
    --port)
        if [ $# -lt 2 ]; then
            printf '%s\n' "run-bridge-demo: --port needs a number" 1>&2
            exit 2
        fi
        shift
        port=$1
        ;;
    -h|--help)
        printf '%s\n' "usage: run-bridge-demo.sh [--lan] [--port <n>]"
        exit 0
        ;;
    *)
        printf '%s\n' "run-bridge-demo: unknown argument '$1'" 1>&2
        exit 2
        ;;
    esac
    shift
done

printf '%s\n' "Building chatview-acp-bridge (release)..."
swift build --package-path "$repo_root" -c release --product chatview-acp-bridge

bridge_bin="$repo_root/.build/release/chatview-acp-bridge"
agent_script="$repo_root/Scripts/fake-acp-agent.sh"
chmod +x "$agent_script"

mkdir -p "$demo_dir"
config_path="$demo_dir/bridge.json"
token="demo-token-please-do-not-reuse"

# The config carries the token, so create it 0600 before writing - the bridge holds its own
# token file at 0600 for the same reason, and a demo that models it as world-readable teaches
# the wrong habit.
: > "$config_path"
chmod 600 "$config_path"

cat > "$config_path" <<EOF
{
  "listen": "$listen_host:$port",
  "agent": { "command": ["$agent_script"] },
  "token": "$token",
  "permissionTimeoutSeconds": 120,
  "turnTimeoutSeconds": 300,
  "logDir": "$demo_dir/sessions",
  "retainEndedSessionsDays": 1
}
EOF

cat <<EOF

--------------------------------------------------------------------------
  chatview-acp-bridge demo
--------------------------------------------------------------------------

  Listening on   ws://$listen_host:$port/acp
  Token          $token
  Session logs   $demo_dir/sessions

  Paste this into the demo app's settings (or into a ChatView transport config):

  {
    "protocol": "acp-remote",
    "transport": {
      "url": "ws://$listen_host:$port/acp",
      "token": "$token",
      "session": "latest"
    }
  }

  iOS Simulator     127.0.0.1 reaches this Mac directly; the default is fine.
  Real iPhone       re-run with --lan and use the address printed above. Both
                    devices must be on the same network.
  Android emulator  10.0.2.2 reaches the host's loopback.

  This token is a demo constant and the bridge is cleartext ws://. That is
  acceptable ONLY on a trusted local network: the token authorizes tool
  execution on this Mac through the agent. Off-LAN, put the bridge behind a
  VPN or a TLS proxy and use wss://.

  Things worth trying by hand:
    - send a message and watch it stream a word at a time
    - every third turn asks a permission; answer it, or leave it and watch
      the bridge default-deny after 120 seconds
    - force-quit the app mid-stream and relaunch: the turn kept running here,
      and the app resumes from its checkpoint instead of replaying everything
    - Ctrl-C this script mid-turn and restart it: the session ends, the
      transcript stays readable

  Ctrl-C to stop.

--------------------------------------------------------------------------

EOF

exec "$bridge_bin" --config "$config_path"
