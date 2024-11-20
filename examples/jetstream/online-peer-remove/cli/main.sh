#!/bin/bash

set -euo pipefail

nats-server --version
nats --version

NATS_URL="nats://localhost:4222"

# Shared config.
cat <<- EOF > shared.conf
accounts: {
  SYS: {
    users: [{user: sys, pass: sys}]
  }
  APP: {
    jetstream: true
    users: [{user: app, pass: app}]
  }
}

system_account: SYS
EOF

# Define the server configs for cluster.
cat <<- EOF > "n1.conf"
server_name: n1
port: 4222
http_port: 8222
include shared.conf
jetstream {
  store_dir: "./n1"
}
cluster: {
  name: hub 
  port: 6222
  routes: [
    nats-route://127.0.0.1:6222,
    nats-route://127.0.0.1:6223,
    nats-route://127.0.0.1:6224,
  ]
}
EOF

cat <<- EOF > "n2.conf"
server_name: n2
port: 4223
include shared.conf
jetstream {
  store_dir: "./n2"
}
cluster: {
  name: hub
  port: 6223
  routes: [
    nats-route://127.0.0.1:6222,
    nats-route://127.0.0.1:6223,
    nats-route://127.0.0.1:6224,
  ]
}
EOF

cat <<- EOF > "n3.conf"
server_name: n3
port: 4224
include shared.conf
jetstream {
  store_dir: "./n3"
}
cluster: {
  name: hub
  port: 6224
  routes: [
    nats-route://127.0.0.1:6222,
    nats-route://127.0.0.1:6223,
    nats-route://127.0.0.1:6224,
  ]
}
EOF

# ### Bring up the cluster

# Start a server for each configuration and sleep a second in
# between so the seeds can startup and get healthy.
echo "Starting n1..."
nats-server -c n1.conf -P n1.pid &
sleep 1

echo "Starting n2..."
nats-server -c n2.conf -P n2.pid &
sleep 1

echo "Starting n3..."
nats-server -c n3.conf -P n3.pid &
sleep 1

# Wait until the servers up and healthy.
echo 'Cluster healthy?'
curl --fail --silent \
  --retry 5 \
  --retry-delay 1 \
  http://localhost:8222/healthz; echo

# Complaing about too many credential types..
#nats context save sys --user sys --password sys
#nats context save app --user app --password app

# Observe the current JS report.
nats --user sys --password sys \
  server report jetstream

# Create a stream to see how an asset behaves.
cat <<- EOF > stream.json
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
  "num_replicas": 3,
  "duplicate_window": 120000000000,
  "sealed": false,
  "deny_delete": false,
  "deny_purge": false,
  "allow_rollup_hdrs": false,
  "allow_direct": false,
  "mirror_direct": false
}
EOF

nats --user app --password app \
  stream add --config stream.json > /dev/null

nats --user app --password app \
  req --count 100 'events.test'

# Remove the peer while online.
nats --user sys --password sys \
  server raft peer-remove -f n3

# Add more data after a peer-remove.
nats --user app --password app \
  req --count 100 'events.test'

# Stop the server.
nats-server --signal ldm=n3.pid

# Add more data.
nats --user app --password app \
  req --count 100 'events.test'

# Start the server.
nats-server -c n3.conf -P n3.pid &

# Wait to observe the behavior.
sleep 3

# Report again.
nats --user sys --password sys \
  server report jetstream
