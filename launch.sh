#!/usr/bin/env bash

set -euo pipefail

# check sudo
if [[ $EUID -ne 0 ]]; then
    SUDO="sudo"
else
    SUDO=""
fi

check_dependencies() {
    # install deps only on ubuntu
    if [ -f /etc/os-release ] && . /etc/os-release && ([ "$ID" = "debian" ] || [ "$ID" = "ubuntu" ]); then
        echo "Running on Debian or Ubuntu"
        local needs_update=false
        local packages_to_install=()

        # check which packages need to be installed
        if ! command -v curl &> /dev/null; then
            echo "'curl' not found. Will install..." >&2
            packages_to_install+=(curl)
            needs_update=true
        fi

        if ! command -v jq &> /dev/null; then
            echo "'jq' not found. Will install..." >&2
            packages_to_install+=(jq)
            needs_update=true
        fi

        # rmw-fastrtps-cpp is installed by default, but we need the dynamic version
        if ! dpkg -l ros-humble-rmw-fastrtps-dynamic-cpp 2> /dev/null | grep -q '^ii'; then
            echo "'ros-humble-rmw-fastrtps-dynamic-cpp' not found. Will install..." >&2
            packages_to_install+=(ros-humble-rmw-fastrtps-dynamic-cpp)
            needs_update=true
        fi

        # install apt packages in one go
        if [ "$needs_update" = true ]; then
            $SUDO apt-get update || exit 1
            $SUDO apt-get install -y "${packages_to_install[@]}" || exit 1
        fi

        # tailscale uses its own installer
        if ! command -v tailscale &> /dev/null; then
            echo "'tailscale' not found. Installing..." >&2
            curl -fsSL https://tailscale.com/install.sh | sh || exit 1
        fi
    fi
}

generate_api_key() {
    curl -s "https://api.tailscale.com/api/v2/oauth/token" \
        -d "client_id=${TAILSCALE_OAUTH_CLIENT_ID}" \
        -d "client_secret=${TAILSCALE_OAUTH_CLIENT_SECRET}"
}

generate_auth_key() {
    local name=$1
    local api_key=$2
    local description
    description=$(printf 'device creation key %s' "$name" | jq -Rs '.')
    curl -s 'https://api.tailscale.com/api/v2/tailnet/-/keys' \
        --request POST \
        --header 'Content-Type: application/json' \
        --header "Authorization: Bearer ${api_key}" \
        --data '{
            "keyType": "auth",
            "description": '"${description}"',
            "expirySeconds": 1440,
            "capabilities": { "devices": { "create": {
                "reusable": false,
                "preauthorized": true,
                "tags": [
                    "'"${TAILSCALE_TAG_NAME}"'"
                ]
            } } }
        }'
}

up() {
    local auth_key="${1:-}"
    local hostname="${2:-}"
    local args=(--ssh --accept-dns=true --accept-routes=true)

    if [ -n "$auth_key" ]; then
        args+=(--auth-key="$auth_key")
    fi
    if [ -n "$hostname" ]; then
        args+=(--hostname="$hostname")
    fi

    if ! $SUDO tailscale up "${args[@]}"; then
        echo "failed to start tailscale" >&2
        exit 1
    fi

    echo "tailscale is up"
}

start() {
    # make sure the env vars are set
    if [ -z "${TAILSCALE_OAUTH_CLIENT_ID:-}" ] || [ -z "${TAILSCALE_OAUTH_CLIENT_SECRET:-}" ]; then
        echo "ensure TAILSCALE_OAUTH_CLIENT_ID and TAILSCALE_OAUTH_CLIENT_SECRET environment variables are set" >&2
        exit 1
    fi

    if [ -z "${TAILSCALE_TAG_NAME:-}" ]; then
        echo "ensure TAILSCALE_TAG_NAME environment variable is set" >&2
        exit 1
    fi

    # generate api key
    api_key="${TAILSCALE_API_KEY:-}"
    if [ -z "$api_key" ]; then
        api_json=$(generate_api_key) || {
            echo "failed to generate api key" >&2
            exit 1
        }
        api_key=$(echo "$api_json" | jq -r '.access_token')
        if [ -z "$api_key" ] || [ "$api_key" = "null" ]; then
            echo "failed to parse api key" >&2
            echo "$api_json" >&2
            exit 1
        fi
        echo "generated api key"
        if [ "$print_keys" = true ]; then
            echo "API Key: $api_key"
        fi
    else
        echo "using api key from environment"
    fi

    name=$(hostname)

    # generate auth key
    auth_json=$(generate_auth_key "$name" "$api_key") || {
        echo "failed to generate auth key" >&2
        exit 1
    }

    auth_key=$(echo "$auth_json" | jq -r '.key')

    if [ -z "$auth_key" ] || [ "$auth_key" = "null" ]; then
        echo "failed to parse auth key" >&2
        echo "$auth_json" >&2
        exit 1
    fi
    echo "generated auth key"
    if [ "$print_keys" = true ]; then
        echo "Auth Key: $auth_key"
    fi

    up "$auth_key" "$name"
}

down() {
    $SUDO tailscale down || true
    echo "tailscale disconnected"
}

logout() {
    $SUDO tailscale down || true
    $SUDO tailscale logout || true
    echo "tailscale logged out"
}

generate_fast_xml() {
    local output_file=$1
    local status_json
    local hostnames

    status_json=$(tailscale status --json) || {
        echo "failed to get tailscale status" >&2
        exit 1
    }

    if [ -z "${TAILSCALE_TAG_NAME:-}" ]; then
        echo "no TAILSCALE_TAG_NAME env var, providing all devices" >&2
        hostnames=$(echo "$status_json" | jq -r '([.Self.DNSName] + 
            ((.Peer // {})|to_entries|map(.value.DNSName)))
            | map(ascii_downcase | split(".")[0])
            | unique
            | sort
            | .[]')
    else
        echo "filtering devices by tag: ${TAILSCALE_TAG_NAME}" >&2
        hostnames=$(echo "$status_json" | jq -r --arg tag "$TAILSCALE_TAG_NAME" '
            ([.Self.DNSName] +
            ((.Peer // {})
                | to_entries
                | map(.value
                    | select((.Tags // []) | index($tag))
                    | .DNSName)))
            | map(ascii_downcase | split(".")[0])
            | unique
            | sort
            | .[]
        ')
    fi

    if [ -z "$hostnames" ]; then
        echo "no hostnames found" >&2
        exit 1
    fi

    # build the locator entries
    local locators=""
    while IFS= read -r host; do
        locators="${locators}                    <locator>
                        <udpv4>
                            <address>${host}</address>
                        </udpv4>
                    </locator>
"
    done <<< "$hostnames"

    # generate the full XML
    local xml
    xml='<?xml version="1.0" encoding="UTF-8" ?>
<profiles xmlns="http://www.eprosima.com/XMLSchemas/fastRTPS_Profiles">
    <transport_descriptors>
        <transport_descriptor>
            <transport_id>TailscaleTransport</transport_id>
            <type>UDPv4</type>
        </transport_descriptor>
    </transport_descriptors>
    <participant profile_name="TailscaleSimple" is_default_profile="true">
        <rtps>
            <userTransports>
                <transport_id>TailscaleTransport</transport_id>
            </userTransports>
            <useBuiltinTransports>true</useBuiltinTransports>
            <builtin>
                <initialPeersList>
'"${locators}"'                </initialPeersList>
            </builtin>
        </rtps>
    </participant>
</profiles>'

    if [ -n "$output_file" ]; then
        echo "$xml" > "$output_file"
        echo "wrote $output_file"
    else
        echo "$xml"
    fi
}

# initialize variables
cmd=""
install_dependencies=false
print_keys=false
output_file=""

while [ $# -gt 0 ]; do
    case "$1" in
        --help)
            cmd=help
            shift
            ;;
        --install-deps)
            install_dependencies=true
            shift
            ;;
        --print-keys)
            print_keys=true
            shift
            ;;
        --write)
            if [ -z "${2:-}" ]; then
                echo "error: --write requires a filename" >&2
                exit 1
            fi
            output_file=$2
            shift 2
            ;;
        start)
            cmd=start
            shift
            ;;
        up)
            cmd=up
            shift
            ;;
        down)
            cmd=down
            shift
            ;;
        logout)
            cmd=logout
            shift
            ;;
        generate-fast-xml)
            cmd=generate-fast-xml
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [ "$install_dependencies" = true ]; then
    check_dependencies
fi

case "${cmd}" in
    start)
        # check if tailscaled daemon is running
        if ! pgrep -x tailscaled &> /dev/null; then
            echo "error: tailscaled daemon is not running" >&2
            exit 1
        fi
        # if tailscale is already connected, error out
        if tailscale status &> /dev/null; then
            echo "error: tailscale is already running" >&2
            exit 1
        fi
        start
        ;;
    up)
        # check if tailscaled daemon is running
        if ! pgrep -x tailscaled &> /dev/null; then
            echo "error: tailscaled daemon is not running" >&2
            exit 1
        fi
        up
        ;;
    down)
        down
        ;;
    logout)
        logout
        ;;
    generate-fast-xml)
        generate_fast_xml "$output_file"
        ;;
    *)
        echo "Usage: $0 [options] <command>"
        echo
        echo "Commands:"
        echo "    start                  Start tailscale with a new device"
        echo "        --print-keys       Print generated API and Auth keys to stdout"
        echo
        echo "    up                     Reconnect to tailscale (device must already be authenticated)"
        echo
        echo "    down                   Disconnect from tailscale (keeps credentials)"
        echo
        echo "    logout                 Disconnect and logout from tailscale (removes credentials)"
        echo
        echo "    generate-fast-xml      Generate fast.xml from tailscale peers (outputs to stdout by default)"
        echo "        --write <file>     Write to <file> instead of stdout"
        echo
        echo "Global Options:"
        echo "    --install-deps         Install necessary dependencies (only on Ubuntu; curl, jq, tailscale)"
        echo "    --help                 Show this help message"
        ;;
esac

exit 0
