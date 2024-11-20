#!/bin/sh

set -euo pipefail

# Create a user for the customer's smart device. Note the use
# of -K to indicate the role and marking it as a bearer token
# which is required for MQTT.
nsc add user --account customer-1 -K iot lightbulb-1

# Output the bearer JWT.
nsc describe user \
  --account customer-1 \
  --name lightbulb-1 \
  --raw > lightbulb-1.jwt

deno cache -q lightbulb.ts

echo 'Running lightbulb...'

# Run the lightbulb using Deno, passing the parameters
# as env variables.
MQTT_URL=nats://localhost:1883 \
IOT_USERNAME=lightbulb-1 \
IOT_PASSWORD=$(cat lightbulb-1.jwt) \
  deno run --allow-net --allow-env --allow-read lightbulb.ts &

sleep 5

# Simulate a couple commands.
nats --context customer-1 pub 'iot.lightbulb-1.commands.on'
nats --context customer-1 pub 'iot.lightbulb-1.commands.off'
