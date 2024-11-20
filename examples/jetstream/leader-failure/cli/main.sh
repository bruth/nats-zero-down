#!/bin/sh

set -euo pipefail

# Share accounts configuration for all nodes.
cat <<- EOF > accounts.conf
accounts: {
  SYS: {
    users: [{user: sys, password: sys}]
  }
  APP: {
    jetstream: true,
    users: [{user: app, password: app}]
  }
}

system_account: SYS
EOF

# Configuration for each node in the cluster.
cat <<- EOF > n1.conf
port: 4222
http_port: 8222
server_name: n1

include accounts.conf

jetstream: {
  store_dir: "./n1"
}

cluster: {
  name: c1,
  port: 6222,
  routes: [
    "nats-route://0.0.0.0:6222",
    "nats-route://0.0.0.0:6223",
    "nats-route://0.0.0.0:6224",
  ],
}
EOF

cat <<- EOF > n2.conf
port: 4223
http_port: 8223
server_name: n2

include accounts.conf

jetstream: {
  store_dir: "./n2"
}

cluster: {
  name: c1,
  port: 6223,
  routes: [
    "nats-route://0.0.0.0:6222",
    "nats-route://0.0.0.0:6223",
    "nats-route://0.0.0.0:6224",
  ],
}
EOF

cat <<- EOF > n3.conf
port: 4224
http_port: 8224
server_name: n3

include accounts.conf

jetstream: {
  store_dir: "./n3"
}

cluster: {
  name: c1,
  port: 6224,
  routes: [
    "nats-route://0.0.0.0:6222",
    "nats-route://0.0.0.0:6223",
    "nats-route://0.0.0.0:6224",
  ],
}
EOF


# Start the servers and sleep for a few seconds to startup.
nats-server -c n1.conf &
N1_PID=$!

nats-server -c n2.conf &
N2_PID=$!

nats-server -c n3.conf &
N3_PID=$!

sleep 3

# Create the app and sys contexts.
nats context save \
  --server "nats://localhost:4222,nats://localhost:4223,nats://localhost:4224" \
  --user app \
  --password app \
  app 

nats context save \
  --server "nats://localhost:4222,nats://localhost:4223,nats://localhost:4224" \
  --user sys \
  --password sys \
  sys  

nats context select app

# Show the server list which will indicate the clusters and
# gateway connections as well as the JetStream server report.
nats --context sys server list
nats --context sys server report jetstream

# Add a basic R3 stream.
nats stream add \
  --retention=limits \
  --storage=file \
  --replicas=3 \
  --discard=old \
  --dupe-window=2m \
  --max-age=-1 \
  --max-msgs=-1 \
  --max-bytes=-1 \
  --max-msg-size=-1 \
  --max-msgs-per-subject=-1 \
  --max-consumers=-1 \
  --allow-rollup \
  --no-deny-delete \
  --no-deny-purge \
  --subjects="orders" \
  ORDERS

# Publish some messages.
nats req orders --count=100 'Message {{Count}}'

# List the streams to show the written messages.
nats stream list

# Force a step down of the leader.
nats stream cluster step-down ORDERS

sleep 2

# Report the new leader.
nats --user sys --password sys server report jetstream

# Publish more messages.
nats req orders --count=100 'Message {{Count}}'

# 200 messages...
nats stream list

# Now we actually kill the leader node completely.
# This will force a re-election among the two remaining nodes.
LEADER=$(nats stream info ORDERS --json | jq -r '.cluster.leader')
echo "$LEADER is the leader"

case $LEADER in
  "n1")
    kill $N1_PID
    ;;
  "n2")
    kill $N2_PID
    ;;
  "n3")
    kill $N3_PID
    ;;
esac

sleep 2

# Publish more messages.
nats req orders --count=100 'Message {{Count}}'

# Ensure we have 300 in the stream.
nats stream list

# Report the new leader...
nats --user sys --password sys server report jetstream

