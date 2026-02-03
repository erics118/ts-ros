# the following for env vars must have already been set, ie with direnv

# oauth client id and secret. make sure not to delete this with delete-key
# possible minimum scopes required: devices, auth keys (read+write)
oauth_client_id := env('TAILSCALE_OAUTH_CLIENT_ID')
oauth_client_secret := env('TAILSCALE_OAUTH_CLIENT_SECRET')

env_tag_name := env('TAILSCALE_TAG_NAME')

# optional api key. if not specified, must be provided as arg to relevant recipes
env_api_key := env('TAILSCALE_API_KEY', '')

# util variables
hostname := shell("hostname")
date := shell("date +%s")

# when creating a device:
# suppose we are on the new device
# we are given the oauth client id/secret
# we use that to generate an api key
# and then we generate an auth key with that api key
# finally, we use this auth key to connect the device to the tailnet

# the api key can have a short lifetime
# the auth key can also have a short lifetime?

# we need to implement checks to make sure these env vars are set

[private]
default:
    @just --list --unsorted

[private]
full tag_name=env_tag_name:
    sudo tailscale down \
    sudo tailscale logout \
    TAILSCALE_API_KEY=$(just generate-api-key | jq -r '.access_token') \
    && echo $TAILSCALE_API_KEY \
    && TAILSCALE_AUTH_KEY=$(just generate-auth-key {{tag_name}} $TAILSCALE_API_KEY | jq -r '.key') \
    && echo $TAILSCALE_AUTH_KEY \
    && sudo tailscale up --reset --auth-key=$TAILSCALE_AUTH_KEY --hostname="$(hostname)"

# generates an api key
[group("client")]
@generate-api-key:
    curl -s "https://api.tailscale.com/api/v2/oauth/token" \
        -d "client_id={{oauth_client_id}}" \
        -d "client_secret={{oauth_client_secret}}" \
            | jq

# lists all devices
[group("api")]
@list-devices api_key=env_api_key:
    curl -s 'https://api.tailscale.com/api/v2/tailnet/-/devices' \
        --header "Authorization: Bearer {{api_key}}" \
            | jq

# creates an auth key
[group("api")]
@generate-auth-key tag_name=env_tag_name api_key=env_api_key:
    curl -s 'https://api.tailscale.com/api/v2/tailnet/-/keys' \
        --request POST \
        --header 'Content-Type: application/json' \
        --header "Authorization: Bearer {{api_key}}" \
        --data '{ \
            "keyType": "auth", \
            "description": "device creation key {{hostname}}-{{date}}", \
            "expirySeconds": 1440, \
            "capabilities": { "devices": { "create": { \
                "reusable": false, \
                "preauthorized": true, \
                "tags": [ \
                    "{{tag_name}}" \
                ] \
            } } } \
        }' | jq

# lists auth keys
[group("api")]
@list-auth-keys api_key=env_api_key:
    curl -s 'https://api.tailscale.com/api/v2/tailnet/-/keys' \
        --header "Authorization: Bearer {{api_key}}" \
            | jq '.keys |= map(select(.keyType == "auth"))'

# lists all keys (auth, api)
[group("api")]
@list-keys api_key=env_api_key:
    curl -s 'https://api.tailscale.com/api/v2/tailnet/-/keys' \
        --header "Authorization: Bearer {{api_key}}" \
            # | jq '.keys |= map(select(.keyType == "client"))'

# delete a key (auth, api)
[group("api")]
@delete-key key_id api_key=env_api_key:
    curl -s "https://api.tailscale.com/api/v2/tailnet/-/keys/{{key_id}}" \
        --request DELETE \
        --header "Authorization: Bearer {{api_key}}" \
        | jq

# checks a key
[group("api")]
@check-key key_id api_key=env_api_key :
    curl "https://api.tailscale.com/api/v2/tailnet/-/keys/{{key_id}}" \
        --header "Authorization: Bearer {{api_key}}"
