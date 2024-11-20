#!/bin/sh

set -euo pipefail

NATS_HUB_URL="nats://0.0.0.0:4222"
NATS_LEAF1_URL="nats://0.0.0.0:4223"
NATS_LEAF2_URL="nats://0.0.0.0:4224"

# ### Hub setup
# Create the operator, generate a signing key (which is a best practice),
# and initialize the default SYS account and sys user.
nsc add operator \
  --generate-signing-key \
  --sys hub

# A follow-up edit of the operator enforces signing keys are used for
# accounts as well. Setting the server URL is a convenience so that
# it does not need to be specified with call `nsc push` while
# the operator is set in the `nsc` environment.
nsc edit operator \
  --require-signing-keys \
  --account-jwt-server-url \
  "$NATS_HUB_URL"

# For this example, we are demonstrating how we can create
# a user which can be used in a leaf node remote and bound
# to the leaf system account.
nsc add account OPS

nsc edit account OPS \
  --sk generate

nsc add user \
  --account OPS ops

# Finally, generate the config for the server.
nsc generate config \
  --nats-resolver \
  --sys-account SYS > hub-resolver.conf

# ### Leaf nodes
# Create the operators and system accounts for the leaf nodes.
# No additional accounts or users are required for this example.
nsc add operator \
  --generate-signing-key \
  --sys leaf1

nsc edit operator \
  --require-signing-keys \
  --account-jwt-server-url \
  "$NATS_LEAF1_URL"

nsc generate config \
  --nats-resolver \
  --sys-account SYS > leaf1-resolver.conf

# Extract the full ID of the system account to specify in the
# remote.
LEAF1_SYS_ID=$(nsc describe account --json SYS| jq -r .sub)

nsc add operator \
  --generate-signing-key \
  --sys leaf2

nsc edit operator \
  --require-signing-keys \
  --account-jwt-server-url \
  "$NATS_LEAF2_URL"

nsc generate config \
  --nats-resolver \
  --sys-account SYS > leaf2-resolver.conf

LEAF2_SYS_ID=$(nsc describe account --json SYS| jq -r .sub)

# Create the hub configuration with leaf nodes enabled.
echo 'Creating the hub server conf...'
cat <<- EOF > hub.conf
server_name: hub
port: 4222
leafnodes: {
  port: 7422
}

include hub-resolver.conf
EOF

# Create the two leaf node configurations each with respective
# resolver config.
echo 'Creating the leaf1 node conf...'
cat <<- EOF > leaf1.conf
server_name: leaf1
port: 4223
leafnodes: {
  remotes: [
    {
      url: "nats-leaf://0.0.0.0:7422",
      credentials: "$NKEYS_PATH/creds/hub/OPS/ops.creds",
      account: ${LEAF1_SYS_ID},
    }
  ]
}

include leaf1-resolver.conf
EOF

echo 'Creating the leaf2 node conf...'
cat <<- EOF > leaf2.conf
server_name: leaf2
port: 4224
leafnodes: {
  remotes: [
    {
      url: "nats-leaf://0.0.0.0:7422",
      credentials: "$NKEYS_PATH/creds/hub/OPS/ops.creds",
      account: ${LEAF2_SYS_ID},
    }
  ]
}

include leaf2-resolver.conf
EOF

# Start the hub server first.
nats-server -c hub.conf > /dev/null 2>&1 &
HUB_PID=$!

sleep 1

# Push the OPS account.
nsc env -o hub 2> /dev/null
nsc push -a OPS

# Now start the two leaf nodes and ensure they startup.
nats-server -c leaf1.conf > /dev/null 2>&1 &
LEAF1_PID=$!

nats-server -c leaf2.conf > /dev/null 2>&1 &
LEAF2_PID=$!

sleep 2

# Define a context which connects to the hub using
# the ops user.
nsc env -o hub 2> /dev/null
nats context save \
  --server=$NATS_HUB_URL \
  --nsc=nsc://hub/OPS/ops \
  hub-ops

# Doing a server list will report on the leaf nodes and
# will not include the hub.
nats --context=hub-ops server list

kill $LEAF1_PID
kill $LEAF2_PID
kill $HUB_PID
