# Multi Region NATS Cluster

This demonstrates a very basic NATS Cluster using only routes across 3 regions.

This should be used in cases where a multi region setup is needed and one requires a stream to be globally deployed and have globally consistent message deduplication.

## Constraints

 * This should be deployed in networks with generally below 100ms latency. For example in GCP using Tier-1 network connectivity in US east, west and central.
 * Streams should generally be R3 when stretched out of a single region to mitigate the big exposure they would have to latency if R5
 * Multi-region streams should not be the default, ideally these are only used for those cases where global deduplication is needed
 * For general streams where eventual consistency is acceptible streams should be bound to a region and replicated into others if desired

## Configuration guidelines

### Server Tags

Each server is tagged with a regional tag, for example, `region:east` or `region:west`. The servers are configured with anti-affinity on this tag using the following configuration:

```
jetstream {
  unique_tag: "region:"
}
```

This ensures that streams that are not specifically bound to a single region will be split across the 3 regions.

### Configuring single region streams

```
$ nats stream add --tag region:east --replicas 3 EAST
...
Cluster Information:

                 Name: c1
               Leader: n1-east
              Replica: n2-east, current, seen 1ms ago
              Replica: n3-east, current, seen 0s ago
```

Note the servers are `n1-east`, `n2-east`, `n3-east`.

### Configuring a global stream

```
$ nats stream add --replicas 3 GLOBAL
...
Cluster Information:

                 Name: c1
               Leader: n1-central
              Replica: n2-east, current, seen 0s ago
              Replica: n3-west, current, seen 0s ago

```

Note here we give no placement directive so the server will spread it across regions due to the `unique_tag` setting.  Servers are `n1-central`, `n2-east` and `n3-west` - 1 per region.

### Configuring replicated streams

To facilitate an eventually consistent but single config set up we show how to create 3 streams:

 * `ORDERS_EAST` listening on subjects `js.in.orders_east`
 * `ORDERS_WEST` listening on subjects `js.in.orders_west`
 * `ORDERS_CENTRAL` listening on subjects `js.in.orders.central`

We then use server mappings in each region to map `js.in.orders` to the in-region subject:

```
accounts {
  one: {
    jetstream: enabled
    mappings: {
      js.in.orders: js.in.orders_central
    }
  }
}
```

We can now publish to one subject and depend on which region we connect to the local stream will handle - then replicate - the data:

```
$ nats --context contexts/central-user.json req js.in.orders 1
{"stream":"ORDERS_CENTRAL", "seq":4}

$ nats --context contexts/east-user.json req js.in.orders 1
{"stream":"ORDERS_EAST", "seq":5}
```

After a short while all streams hold the same data.

```
╭───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│                                                             Stream Report                                                             │
├────────────────┬─────────┬──────────────────────┬───────────┬──────────┬───────┬──────┬─────────┬─────────────────────────────────────┤
│ Stream         │ Storage │ Placement            │ Consumers │ Messages │ Bytes │ Lost │ Deleted │ Replicas                            │
├────────────────┼─────────┼──────────────────────┼───────────┼──────────┼───────┼──────┼─────────┼─────────────────────────────────────┤
│ GLOBAL         │ File    │                      │         0 │ 0        │ 0 B   │ 0    │       0 │ n1-central, n2-west*, n3-east       │
│ ORDERS_CENTRAL │ File    │ tags: region:central │         0 │ 5        │ 399 B │ 0    │       0 │ n1-central, n2-central*, n3-central │
│ ORDERS_EAST    │ File    │ tags: region:east    │         0 │ 5        │ 405 B │ 0    │       0 │ n1-east*, n2-east, n3-east          │
│ ORDERS_WEST    │ File    │ tags: region:west    │         0 │ 5        │ 456 B │ 0    │       0 │ n1-west*, n2-west, n3-west          │
╰────────────────┴─────────┴──────────────────────┴───────────┴──────────┴───────┴──────┴─────────┴─────────────────────────────────────╯
```

This allows portable publishers to be built, consumers will need to know the region they are in and bind to the correct stream.


