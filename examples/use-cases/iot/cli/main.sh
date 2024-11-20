#!/bin/sh

set -euo pipefail

export NATS_URL="nats://localhost:4222,nats://localhost:4223,nats://localhost:4224"
export MQTT_URL="nats://localhost:1883"

# Setup the operator and generate the resolver configuration.
sh setup-operator.sh

# Setup the `service` and `customer-1` accounts.
sh setup-accounts.sh

# Start the cluster and wait a few seconds to choose the leader.
nats-server -c n1.conf > /dev/null 2>&1 &
nats-server -c n2.conf > /dev/null 2>&1 &
nats-server -c n3.conf > /dev/null 2>&1 &

sleep 3

# Ensure the cluster is healthy.
curl --fail --silent \
  --retry 5 \
  --retry-delay 1 \
  http://localhost:8222/healthz > /dev/null

# Push the accounts to the cluster.
nsc push -A

# Create a admin user for the customer so inspect traffic.
nsc add user --account customer-1 -K admin customer-1
nats context save customer-1 --nsc nsc://example/customer-1/customer-1

# Setup general subscribers to observe the messages...
nats --context customer-1 sub 'iot.>' &
nats --context customer-1 sub 'mobile.>' &

echo 'Starting the lightbulb device...'
sh start-lightbulb.sh

echo 'Starting the service...'
sh start-service.sh

