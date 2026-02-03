# tailscale-ros

tailscale automation scripts for usage in ROS

The `justfile` is just for development purposes.

`launch.sh` is a fully self-contained script that is used to set up tailscale.
requires `curl`, `jq`, and `tailscale` to be installed on the system, but it
will install them if they are not found.

## how to use

### configure tailscale

create a tailscale oauth app to get a client ID and secret: 
https://tailscale.com/kb/1215/oauth-clients

Then, create a tag for the devices to use. This repo uses `tag:ros-devices`.

### configure env vars

<details>
<summary>for nixos</summary>
use direnv. put the content below into `.envrc` and add `use flake` to the top of the file.
</details>

set up these environment variables: (or use direnv or similar)

set the following variables:

```sh
# tailscale oauth client id and secret
export TAILSCALE_OAUTH_CLIENT_ID=
export TAILSCALE_OAUTH_CLIENT_SECRET=

# the name of the tailscale tag to use
# required for starting tailscale
export TAILSCALE_TAG_NAME="tag:ros-device"

# choose a domain id. must be the same across devices
export ROS_DOMAIN_ID=14

# this must be 0
export ROS_LOCALHOST_ONLY=0

# this cannot be changed either
export RMW_IMPLEMENTATION=rmw_fastrtps_dynamic_cpp

# path to the fast.xml file. this sets it automatically.
# you can set it to whatever you want, but this is convenient
export FASTRTPS_DEFAULT_PROFILES_FILE=$(pwd)/fast.xml
```

### set up fastrtps

in `./fast.xml`, add in all the (subscriber) ip/hostnames.
this is necessary for the publisher to talk to the subscriber.

see `./fast.example.xml` for an example.

The subscribers do not need to have this configured, only the publishers.

You can do this automatically with `./launch.sh generate-fast-xml --write fast.xml`

If you set `TAILSCALE_TAG_NAME`, the generated file will only include devices with that tag.

### set up tailscale

If using a `.env` file, make sure to source it first with `source .env`

Run `./launch.sh start`. Add the `--print-keys` flag if you wish to see the generated api and auth keys.

This uses the oauth client to authenticate with tailscale to create an api key,
which then creates an auth key, and then sets up tailscale for this device,
using a tag to ensure the device persists.

### set up ros

TODO: this is gone

these are the standard steps.

<details>
<summary>for nixos</summary>
the `flake.nix` sets everything up.

build the ros2 package with `colcon build --symlink-install`

run `source install/setup.zsh`, run `nix develop`, or use direnv to automatically enter the shell.
</details>

install ros2 humble

setup ros2, `source /opt/ros/humble/setup.zsh`

build the ros2 package with `colcon build --symlink-install`

run `source install/setup.zsh`

### run ros

`src/py_pubsub` is the tutorial publisher/subscriber code.

run `ros2 run py_pubsub listener` on one device 
and `ros2 run py_pubsub talker` on the other device.
they should be communicating with each other.

## how it works

Tailscale auth and api keys are limited to 90 day lifespans, so this script instead uses the oauth client.
This allows the script to generate new api and auth keys on each run, allowing for long term usage without human intervention.

By default, devices need to re-authenticate every 90 days.
However, by using tags, devices will not need to re-authenticate.

Tailscale does not support multicast, which ROS2 uses for nodes to find each other.
To work around this, we generate a `fast.xml` file for fastrtps to use for communication over tailscale.
This file contains the ips/hostnames of all the devices in the tailnet.

## notes

references:
- https://danaukes.com/notebook/ros2/30-configuring-ros-over-tailscale/
- https://github.com/tailscale/tailscale/issues/11972
- https://kamathrobotics.com/ros-2-and-vpns
