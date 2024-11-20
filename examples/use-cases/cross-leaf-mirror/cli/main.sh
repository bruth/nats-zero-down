#!/bin/bash

set -euo pipefail

unset NATS_URL

# ### Bootstrap the operator

# Create the operator, generate a signing key (which is a best practice),
# and initialize the default SYS account and sys user.
nsc add operator --generate-signing-key --sys --name local

# A follow-up edit of the operator enforces signing keys are used for
# accounts as well. Setting the server URL is a convenience so that
# it does not need to be specified with call `nsc push`.
nsc edit operator --require-signing-keys \
  --account-jwt-server-url "nats://127.0.0.1:4222"

# This command generates the bit of configuration to be used by the server
# to setup the embedded JWT resolver.
nsc generate config --nats-resolver --sys-account SYS > resolver.conf

# ### Server configs for supercluster
#
# This emulates a supercluster consisting of three clusters with
# three nodes each.

cat <<- EOF > hub-shared.conf
jetstream: {
  domain: hub
}
include resolver.conf
EOF

cat <<- EOF > gateway-routes.conf
gateways: [
  {name: east, urls: [
    nats://localhost:7222,
    nats://localhost:7223,
    nats://localhost:7224,
  ]},
  {name: west, urls: [
    nats://localhost:7225,
    nats://localhost:7226,
    nats://localhost:7227,
  ]},
  {name: central, urls: [
    nats://localhost:7228,
    nats://localhost:7229,
    nats://localhost:7230,
  ]},
]
EOF

# Define the server configs for east cluster.
cat <<- EOF > "east-az1.conf"
server_name: east-az1
port: 4222
http_port: 8222
include hub-shared.conf
cluster: {
  name: east
  port: 6222
  routes: [
    nats-route://127.0.0.1:6222,
    nats-route://127.0.0.1:6223,
    nats-route://127.0.0.1:6224,
  ]
}
gateway {
  name: east
  port: 7222
  include gateway-routes.conf
}
leafnodes {
  port: 7422
}
EOF

cat <<- EOF > "east-az2.conf"
server_name: east-az2
port: 4223
include hub-shared.conf
cluster: {
  name: east
  port: 6223
  routes: [
    nats-route://127.0.0.1:6222,
    nats-route://127.0.0.1:6223,
    nats-route://127.0.0.1:6224,
  ]
}
gateway {
  name: east
  port: 7223
  include gateway-routes.conf
}
leafnodes {
  port: 7423
}
EOF

cat <<- EOF > "east-az3.conf"
server_name: east-az3
port: 4224
include hub-shared.conf
cluster: {
  name: east
  port: 6224
  routes: [
    nats-route://127.0.0.1:6222,
    nats-route://127.0.0.1:6223,
    nats-route://127.0.0.1:6224,
  ]
}
gateway {
  name: east
  port: 7224
  include gateway-routes.conf
}
leafnodes {
  port: 7424
}
EOF

# Server configs for west cluster.
cat <<- EOF > "west-az1.conf"
server_name: west-az1
port: 4225
http_port: 8223
include hub-shared.conf
cluster: {
  name: west
  port: 6225
  routes: [
    nats-route://127.0.0.1:6225,
    nats-route://127.0.0.1:6226,
    nats-route://127.0.0.1:6227,
  ]
}
gateway {
  name: west
  port: 7225
  include gateway-routes.conf
}
leafnodes {
  port: 7425
}
EOF

cat <<- EOF > "west-az2.conf"
server_name: west-az2
port: 4226
include hub-shared.conf
cluster: {
  name: west
  port: 6226
  routes: [
    nats-route://127.0.0.1:6225,
    nats-route://127.0.0.1:6226,
    nats-route://127.0.0.1:6227,
  ]
}
gateway {
  name: west
  port: 7226
  include gateway-routes.conf
}
leafnodes {
  port: 7426
}
EOF

cat <<- EOF > "west-az3.conf"
server_name: west-az3
port: 4227
include hub-shared.conf
cluster: {
  name: west
  port: 6227
  routes: [
    nats-route://127.0.0.1:6225,
    nats-route://127.0.0.1:6226,
    nats-route://127.0.0.1:6227,
  ]
}
gateway {
  name: west
  port: 7227
  include gateway-routes.conf
}
leafnodes {
  port: 7427
}
EOF

# Server configs for central cluster.
cat <<- EOF > "central-az1.conf"
server_name: central-az1
port: 4228
http_port: 8224
include hub-shared.conf
cluster: {
  name: central
  port: 6228
  routes: [
    nats-route://127.0.0.1:6228,
    nats-route://127.0.0.1:6229,
    nats-route://127.0.0.1:6230,
  ]
}
gateway {
  name: central
  port: 7228
  include gateway-routes.conf
}
leafnodes {
  port: 7428
}
EOF

cat <<- EOF > "central-az2.conf"
server_name: central-az2
port: 4229
include hub-shared.conf
cluster: {
  name: central
  port: 6229
  routes: [
    nats-route://127.0.0.1:6228,
    nats-route://127.0.0.1:6229,
    nats-route://127.0.0.1:6230,
  ]
}
gateway {
  name: central
  port: 7229
  include gateway-routes.conf
}
leafnodes {
  port: 7429
}
EOF

cat <<- EOF > "central-az3.conf"
server_name: central-az3
port: 4230
include hub-shared.conf
cluster: {
  name: central
  port: 6230
  routes: [
    nats-route://127.0.0.1:6228,
    nats-route://127.0.0.1:6229,
    nats-route://127.0.0.1:6230,
  ]
}
gateway {
  name: central
  port: 7230
  include gateway-routes.conf
}
leafnodes {
  port: 7430
}
EOF

# ### Bring up the supercluster

# Start a server for each configuration and sleep a second in
# between so the seeds can startup and get healthy.
for c in $(ls *-az*.conf); do
  echo "Starting.. $c"
  nats-server -c $c > /dev/null 2>&1 &
  sleep 1
done

# Wait until the servers up and healthy.
echo 'East cluster healthy?'
curl --fail --silent \
  --retry 5 \
  --retry-delay 1 \
  http://localhost:8222/healthz; echo

echo 'West cluster healthy?'
curl --fail --silent \
  --retry 5 \
  --retry-delay 1 \
  http://localhost:8223/healthz; echo

echo 'Central cluster healthy?'
curl --fail --silent \
  --retry 5 \
  --retry-delay 1 \
  http://localhost:8224/healthz; echo

# ### Setup APP account
#
# Next we need to create an account intended for application usage. It is
# currently a two-step process to create the account, followed by
# generating the signing key and setting JetStream limits (default is disabled).
nsc add account APP
nsc edit account APP \
  --sk generate \
  --js-disk-storage -1 \
  --js-mem-storage -1

# Push to the cluster.
nsc push -a APP

# ### Setup users for leaf connections

# The `leaf-east` user has restricted permissions to allow for mirrors
# of the "events" stream to be created. The sub is required since
# creating a stream with a mirror internally sends a "create consumer"
# request which needs to traverse the leaf node. The two forms account for
# the non-filtered and filtered forms.
# The `$JS.M.*` pub permission is required since this this is the default
# "deliver subject" structure for mirrors. A concrete subject may look like
# this `$JS.M.iRg4nabNe`. There is an option to override the deliver prefix
# in the mirror config to have more control over permissions.
# The `_GR_.>` pub permission is the standard reply subject across gateways.
nsc add user --account APP leaf-east \
  --allow-sub '$JS.leaf-east.API.CONSUMER.CREATE.events' \
  --allow-sub '$JS.leaf-east.API.CONSUMER.CREATE.events.>' \
  --allow-sub 'leaf-east.hello' \
  --allow-pub 'leaf-west.events.M.*' \
  --allow-pub '_GR_.>' \
  --allow-pub '_INBOX_west.>'

# The `leaf-west` user needs to be able to create a consumer (implicitly)
# when the local stream mirror is setup and subscribe to the deliver subject
# `$JS.M.*`. The `$JSC.R.*` subject is the default reply subject between a
# leaf node to a cluster.
nsc add user --account APP leaf-west \
  --allow-pub '$JS.leaf-east.API.CONSUMER.CREATE.events' \
  --allow-pub '$JS.leaf-east.API.CONSUMER.CREATE.events.>' \
  --allow-pub 'leaf-east.hello' \
  --allow-sub '_INBOX_west.>' \
  --allow-sub 'leaf-west.events.M.*' \
  --allow-sub '$JSC.R.*'

# ### Create the leaf configurations

# The leafs do not have their own authentication nor
# do they extend the operator of the hub.
cat <<- EOF > "leaf-east.conf"
server_name: leaf-east
port: 4231
jetstream: {
  domain: leaf-east
  store_dir: /tmp/leaf-east
}
leafnodes {
  remotes: [
    {
      urls: [
        "nats-leaf://127.0.0.1:7422"
        "nats-leaf://127.0.0.1:7423"
        "nats-leaf://127.0.0.1:7424"
      ]
      credentials: "/nsc/nkeys/creds/local/APP/leaf-east.creds"
    }
  ]
}
EOF

cat <<- EOF > "leaf-west.conf"
server_name: leaf-west
port: 4232
jetstream: {
  domain: leaf-west
  store_dir: /tmp/leaf-west
}
leafnodes {
  remotes: [
    {
      urls: [
        "nats-leaf://127.0.0.1:7425"
        "nats-leaf://127.0.0.1:7426"
        "nats-leaf://127.0.0.1:7427"
      ]
      credentials: "/nsc/nkeys/creds/local/APP/leaf-west.creds"
    }
  ]
}
EOF

# Startup leaf nodes.
nats-server -DV -c leaf-east.conf > /dev/null 2>&1 &
nats-server -DV -c leaf-west.conf > /dev/null 2>&1 &

sleep 1

# ### Setup leaf contexts
#
# Save a context for the east and west leaf node. Notice there
# are no permissions setup since the leaf nodes do not require
# any local authentication.
nats context save leaf-east \
  --server 'nats://127.0.0.1:4231'

nats context save leaf-west \
  --server 'nats://127.0.0.1:4232'

# Next we create the origin stream in the "east" leaf node.
cat <<- EOF > leaf-east-origin.json
{
  "name": "events",
  "subjects": [
    "events.*"
  ],
  "retention": "limits",
  "max_consumers": -1,
  "max_msgs_per_subject": -1,
  "max_msgs": -1,
  "max_bytes": -1,
  "max_age": 0,
  "max_msg_size": -1,
  "storage": "file",
  "discard": "old",
  "num_replicas": 1,
  "duplicate_window": 120000000000,
  "sealed": false,
  "deny_delete": false,
  "deny_purge": false,
  "allow_rollup_hdrs": false,
  "allow_direct": false,
  "mirror_direct": false
}
EOF

nats --context leaf-east stream add \
  --config leaf-east-origin.json

# Now we can create the mirror in the west leaf node.
cat <<- EOF > leaf-west-mirror.json
{
  "name": "events",
  "retention": "limits",
  "max_consumers": -1,
  "max_msgs_per_subject": -1,
  "max_msgs": -1,
  "max_bytes": -1,
  "max_age": 0,
  "max_msg_size": -1,
  "storage": "file",
  "discard": "old",
  "num_replicas": 1,
  "mirror": {
    "name": "events",
    "external": {
      "api": "\$JS.leaf-east.API",
      "deliver": "leaf-west.events"
    }
  },
  "sealed": false,
  "deny_delete": false,
  "deny_purge": false,
  "allow_rollup_hdrs": false,
  "allow_direct": false,
  "mirror_direct": false
}
EOF

nats --context leaf-west stream add \
  --config leaf-west-mirror.json

# Publish a few events to the origin stream in east.
nats --context leaf-east req 'events.1' ''
nats --context leaf-east req 'events.2' ''
nats --context leaf-east req 'events.3' ''

# List the streams in both east and west to observe the state.
nats --context leaf-east stream list
nats --context leaf-west stream list

# Start up a reply service in east.
nats --context leaf-east reply \
  leaf-east.hello 'hello from leaf-east' &
sleep 1

# Send a request to the `leaf-east.hello` subject
# that only exists in the leaf-east. This also uses an
# inbox-prefix so the pub permission in east can be constrained.
nats --context leaf-west \
  --inbox-prefix _INBOX_west \
  request leaf-east.hello \
  'hi from leaf-west!'
