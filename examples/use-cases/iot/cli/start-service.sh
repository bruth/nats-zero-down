#!/bin/sh

set -euo pipefail

# Create the user for the service.
nsc add user --account service service \
  --allow-pub "*.iot.*.commands.>" \
  --allow-sub "*.iot.*.events.>"

# Generate the creds for the service.
nsc generate creds \
  --account service \
  --name service > service.creds

deno cache -q service.ts

# Run the service using Deno, passing the service creds.
NATS_CREDS=service.creds \
  deno run --allow-net --allow-env --allow-read service.ts
