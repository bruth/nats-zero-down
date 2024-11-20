#!/bin/bash

set -euo pipefail

NATS_URL=nats://localhost:4222

cat <<- EOF > "server.conf"
http_port: 8222
jetstream: {}
accounts: {
  A: {
    jetstream: true
    users: [
      {user: usera, password: usera}
    ]
    exports: [
      # For account B to publish messages to the orders stream.
      {service: "orders.*"}

      # For account B to bind to the worker-B consumer on orders stream.
      # This is specific to a push consumer with flow control enabled.
      {stream: "worker-B.orders"}
      {service: "\$JS.ACK.orders.worker-B.>"}
      {service: "\$JS.FC.orders.worker-B.>"}
    ]
  }

  B: {
    jetstream: true
    users: [
      {user: userb, password: userb}
    ]
    imports: [
      # Import ability to publish (request) messages into the orders stream.
      {service: {account: A, subject: "orders.*"}}

      # Import ability to subscribe to the target subject on worker-B consumer.
      {stream: {account: A, subject: "worker-B.orders"}}
      {service: {account: A, subject: "\$JS.ACK.orders.worker-B.>"}}
      {service: {account: A, subject: "\$JS.FC.orders.worker-B.>"}}
    ]
  }
}
EOF

# Start the server.
echo 'Starting the server...'
nats-server -c server.conf > /dev/null 2>&1 &

nats context save A \
  --user usera \
  --password usera

nats context save B \
  --user userb \
  --password userb

# Add the stream in account A
nats --context A stream add orders \
  --subjects orders.* \
  --retention=limits \
  --storage=file \
  --replicas=1 \
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
  --no-deny-purge

# Confirm account B can publish to the stream.
nats --context B req orders.1 "{}"

# Report the stream.
#nats --context A stream report

# Create a consumer in account A whose API will be exported for B.
# Specifically, this requires the `target` subject as a stream, and
# the `$JS.ACK` subject to acknowledge messages.
nats --context A consumer add orders worker-B \
  --replicas 1 \
  --deliver all \
  --deliver-group "" \
  --target worker-B.orders \
  --ack explicit \
  --replay instant \
  --filter "" \
  --heartbeat "2s" \
  --flow-control \
  --max-deliver="-1" \
  --max-pending 128 \
  --no-headers-only \
  --backoff=none

# Subscribe and consume one message from the imported subject
# and ack it.
nats --context B sub --ack worker-B.orders --count 1

# Notice the consumer report shows no unprocessed messages.
nats --context A consumer report orders
