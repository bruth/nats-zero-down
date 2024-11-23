#!/bin/sh

# The `nats` CLI utilizes the `NATS_URL` environment variable if set.
# However, if you want to manage different _contexts_ for connecting
# or authenticating, check out the `nats context` commands.
# For example:
# ```
# nats context save --server=$NATS_URL local
# ```


# Start a nats-server in the background.
nats-server &

NATS_URL="${NATS_URL:-nats://localhost:4222}"

# Publish a message to the subject 'greet.joe'. Nothing will happen
# since the subscription is not yet setup.
nats pub 'greet.joe' 'hello'

# Let's start a subscription in the background that will print
# the output to stdout.
nats sub 'greet.*' &

# This just captures the process ID of the previous command in this shell.
SUB_PID=$!

# Tiny sleep to ensure the subscription connected.
sleep 0.5

# Now we can publish a couple times..
nats pub 'greet.joe' 'hello'
nats pub 'greet.pam' 'hello'
nats pub 'greet.bob' 'hello'

# Remove the subscription.
kill $SUB_PID

# Publishing again will not result in anything.
nats pub 'greet.bob' 'hello'
