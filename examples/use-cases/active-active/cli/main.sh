#!/bin/sh

set -euo pipefail

# Define the system account to be included by all configurations.
cat <<- EOF > accounts.conf
accounts: {
  APP: {
    jetstream: enabled
    users: [{user: app, password: app}]
  },
  \$SYS: {
    users: [{user: sys, password: sys}]
  }
}
EOF



# Define configuration for two nodes.
cat <<- EOF > east.conf
port: 4222
http_port: 8222
server_name: east

include accounts.conf

jetstream: {
  store_dir: "./east"
}

cluster: {
  name: east,
  port: 6222,
  routes: [
    "nats-route://0.0.0.0:6222"
  ],
}

gateway: {
  name: east,
  port: 7222,
  gateways: [
    {name: "east", urls: ["nats://0.0.0.0:7222"]},
    {name: "west", urls: ["nats://0.0.0.0:7223"]},
    {name: "central", urls: ["nats://0.0.0.0:7224"]},
  ]
}
EOF

cat <<- EOF > west.conf
port: 4223
http_port: 8223
server_name: west

include accounts.conf

jetstream: {
  store_dir: "./west"
}

cluster: {
  name: west,
  port: 6223,
  routes: [
    "nats-route://0.0.0.0:6223"
  ],
}

gateway: {
  name: west,
  port: 7223,
  gateways: [
    {name: "east", urls: ["nats://0.0.0.0:7222"]},
    {name: "west", urls: ["nats://0.0.0.0:7223"]},
    {name: "central", urls: ["nats://0.0.0.0:7224"]},
  ]
}
EOF

cat <<- EOF > central.conf
port: 4224
http_port: 8224
server_name: central

include accounts.conf

jetstream: {
  store_dir: "./central"
}

cluster: {
  name: central
  port: 6224
  routes: [
    "nats-route://0.0.0.0:6224"
  ],
}

gateway: {
  name: central,
  port: 7224,
  gateways: [
    {name: "east", urls: ["nats://0.0.0.0:7222"]},
    {name: "west", urls: ["nats://0.0.0.0:7223"]},
    {name: "central", urls: ["nats://0.0.0.0:7224"]},
  ]
}
EOF


# Start the servers and sleep for a few seconds to startup.
nats-server -c east.conf > /dev/null 2>&1 &
EAST_PID=$!

nats-server -c west.conf > /dev/null 2>&1 &
WEST_PID=$!

nats-server -c central.conf > /dev/null 2>&1 &
CENTRAL_PID=$!

sleep 3

# Wait until the servers are healthy.
curl --fail --silent \
  --retry 10 \
  --retry-delay 1 \
  http://localhost:8222/healthz > /dev/null

curl --fail --silent \
  --retry 10 \
  --retry-delay 1 \
  http://localhost:8223/healthz > /dev/null

curl --fail --silent \
  --retry 10 \
  --retry-delay 1 \
  http://localhost:8224/healthz > /dev/null

# Same come contexts.
nats context save app \
  --server "nats://localhost:4222" \
  --user app --password app

nats context save sys \
  --server "nats://localhost:4222" \
  --user sys --password sys

# Create a stream on each node without any sourcing.
echo 'Creating the streams...'
nats --context=app stream add \
  --config east.json events-east > /dev/null

nats --context=app stream add \
  --config west.json events-west > /dev/null

nats --context=app stream add \
  --config central.json events-central > /dev/null

# Edit the streams to source from the other nodes.
nats --context=app stream edit \
  --config east-edit.json \
  --force events-east > /dev/null

nats --context=app stream edit \
  --config west-edit.json \
  --force events-west > /dev/null

nats --context=app stream edit \
  --config central-edit.json \
  --force events-central > /dev/null

# Run the application indicating the base context, the preferred region, and
# the URLs for each region eligible for failover.
echo 'Starting the application and running for 5 seconds...'
/app \
  --context=app \
  --region=east \
  --stream=events \
  --urls=east=nats://localhost:4222,west=nats://localhost:4223,central=nats://localhost:4224 \
  &
APP_PID=$!

sleep 5

echo 'Report the streams and consumers on events-east...'
nats --context=app -s nats://localhost:4222 stream report
nats --context=app -s nats://localhost:4222 consumer report events-east

echo 'View a message in each of the streams...'
nats --context=app -s nats://localhost:4222 stream view events-east 1
nats --context=app -s nats://localhost:4222 stream view events-west 1
nats --context=app -s nats://localhost:4222 stream view events-central 1

kill $EAST_PID
echo 'Killed east'

echo 'Observe the failover and sleep for 10...'
sleep 10

echo 'Report the streams and consumers on events-west...'
nats --context=app -s nats://localhost:4223 stream report
nats --context=app -s nats://localhost:4223 consumer report events-west

nats --context=sys -s nats://localhost:4223 server report jetstream

echo 'Starting up east...'
nats-server -c east.conf > /dev/null 2>&1 &
EAST_PID=$!

sleep 3

curl --fail --silent \
  --retry 10 \
  --retry-delay 1 \
  http://localhost:8222/healthz > /dev/null

echo 'East is back up'

sleep 2

echo 'Observe the streams...'
nats --context=app -s nats://localhost:4222 stream report
nats --context=app -s nats://localhost:4223 consumer report events-west
nats --context=app -s nats://localhost:4222 consumer report events-east

nats --context=sys -s nats://localhost:4222 server report jetstream 

kill $WEST_PID
kill $CENTRAL_PID
echo 'Killed west'

sleep 10

echo 'Report streams and consumers on events-east...'
nats --context=app -s nats://localhost:4222 stream report
nats --context=app -s nats://localhost:4222 consumer report events-east

nats --context=sys -s nats://localhost:4222 server report jetstream 

echo 'Starting up west...'
nats-server -c west.conf > /dev/null 2>&1 &
WEST_PID=$!

sleep 3

curl --fail --silent \
  --retry 10 \
  --retry-delay 1 \
  http://localhost:8223/healthz > /dev/null

echo 'West is back up'

sleep 3

echo 'Report the streams...'
nats --context=app -s nats://localhost:4222 stream report

kill -SIGINT $APP_PID

sleep 2
