#!/bin/sh

set -euo pipefail

# Define configuration with JetStream enabled and two users.
# The goal is to have a shared KV, but each user can only put/get
# keys that are scoped to them. This also leverages the
# [private inbox](/examples/auth/private-inbox/cli) pattern to
# ensure another user can top snoop on shared `_INBOX` responses.
# *Note, the `$` is escaped here to prevent bash variable substitution.*
cat <<- EOF > auth.conf
jetstream: {}

authorization: {
  users: [
    {
      user: admin, password: "admin",
      permissions: {
        subscribe: ">",
        publish: ">"
      }
    },
    {
      user: router001, password: "router001",
      permissions: {
        subscribe: [
          "_INBOX_router001.>"
        ],
        publish: [
          "\$JS.API.STREAM.INFO.KV_test_kv",
          "\$KV.test_kv.dev.001.>",
          "\$JS.API.DIRECT.GET.KV_test_kv.\$KV.test_kv.dev.001.>"
        ]
      }
    },
    {
      user: router002, password: "router002",
      permissions: {
        subscribe: [
          "_INBOX_router002.>"
        ],
        publish: [
          "\$JS.API.STREAM.INFO.KV_test_kv",
          "\$KV.test_kv.dev.002.>",
          "\$JS.API.DIRECT.GET.KV_test_kv.\$KV.test_kv.dev.002.>"
        ]
      }
    },

  ]
}
EOF

# Start the servers and sleep to startup.
nats-server -c auth.conf > /dev/null 2>&1 &

sleep 1

# Save a context for each user.
nats context save \
  --user admin \
  --password admin \
  admin

nats context save \
  --user router001 \
  --password router001 \
  --inbox-prefix _INBOX_router001 \
  router001

nats context save \
  --user router002 \
  --password router002 \
  --inbox-prefix _INBOX_router002 \
  router002

# Create a KV "test_kv" with admin user.
nats --context=admin kv add \
  --history=1 \
  --ttl=0 \
  --replicas=1 \
  --max-value-size=-1 \
  --max-bucket-size=-1 \
  --storage=file \
  test_kv

# Have router001 user put and get a key.
nats --context=router001 \
  kv put test_kv 'dev.001.temp' '80c'

nats --context=router001 \
  kv get test_kv 'dev.001.temp'

# Have router002 attempt to get `dev.001` key.
nats --context=router002 \
  kv get test_kv 'dev.001.temp'

