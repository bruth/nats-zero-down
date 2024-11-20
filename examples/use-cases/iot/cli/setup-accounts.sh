#!/bin/sh

set -euo pipefail

# Next we create an account for the cloud service.
nsc add account service
nsc edit account service \
  --js-disk-storage -1 \
  --js-mem-storage -1

nsc edit account service --sk generate

# Next we create an account for a customer which provides isolation
# for all messages traversing IoT and mobile devices.
nsc add account customer-1
nsc edit account customer-1 \
  --js-disk-storage -1 \
  --js-mem-storage -1

# Export service (request-reply) from customer account to receive
# commands from the cloud service.
nsc add export --account customer-1 \
  --service \
  --subject "iot.*.commands.>" \
  --response-type "Singleton"

# Export event stream from customer account to be received
# by the cloud service.
nsc add export --account customer-1 \
  --subject "iot.*.events.>"

# Import a service from the customer account in order
# to invoke commands against their devices.
nsc add import --account service \
  --service \
  --src-account customer-1 \
  --remote-subject "iot.*.commands.>" \
  --local-subject "customer-1.iot.*.commands.>"

# Import the event stream from the customer account.
nsc add import --account service \
  --src-account customer-1 \
  --remote-subject "iot.*.events.>" \
  --local-subject "customer-1.iot.*.events.>"

# Generate the signing key for the Mobile devices for this
# customer.
SK1=$(nsc edit account customer-1 --sk generate 2>&1 | grep -o '\(A[^"]\+\)')
nsc edit signing-key \
  --account customer-1 \
  --sk $SK1 \
  --role mobile \
  --allow-pub "iot.*.commands.>" \
  --allow-sub "iot.*.events" \
  --allow-pub-response

# Generate the signing key for the IoT devices for this
# customer.
SK2=$(nsc edit account customer-1 --sk generate 2>&1 | grep -o '\(A[^"]\+\)')
nsc edit signing-key \
  --account customer-1 \
  --sk $SK2 \
  --role iot \
  --bearer \
  --allow-pub "iot.{{name()}}.events.>" \
  --allow-sub "iot.{{name()}}.commands.>" \
  --allow-sub "iot.{{name()}}.commands" \
  --allow-pub-response

# Generate the signing key for the IoT devices for this
# customer.
SK3=$(nsc edit account customer-1 --sk generate 2>&1 | grep -o '\(A[^"]\+\)')
nsc edit signing-key \
  --account customer-1 \
  --sk $SK3 \
  --role admin

