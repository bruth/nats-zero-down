import {
  connect,
  credsAuthenticator,
  StringCodec,
} from "https://deno.land/x/nats@v1.10.2/src/mod.ts";

// Get the passed NATS_URL or fallback to the default. This can be
// a comma-separated string.
const servers = Deno.env.get("NATS_URL") || "nats://localhost:4222";
const creds = Deno.env.get("NATS_CREDS");

const f = await Deno.open(creds, {read: true});
const credsData = await Deno.readAll(f);
Deno.close(f.rid);

console.log("Loaded the creds file...")

// Create a client connection to an available NATS server.
const nc = await connect({
  servers: servers.split(","),
  authenticator: credsAuthenticator(credsData),
});

console.log("Service connected to NATS...")

// NATS message payloads are byte arrays, so we need to have a codec
// to serialize and deserialize payloads in order to work with them.
// Another built-in codec is JSONCodec or you can implement your own.
const sc = StringCodec();
const empty = sc.encode("");

// Publish a message with an at-most-once guarantee to turn the light on.
await nc.publish("customer-1.iot.lightbulb-1.commands.on");

// Emulate an at-least-once guarantee to turn the light off. Subscribe
// and wait for the event.
const sub = nc.subscribe("customer-1.iot.lightbulb-1.events.off");
await nc.publish("customer-1.iot.lightbulb-1.commands.off");
for await (const msg of sub) {
  console.log("confirmed lightbulb is off")
  break;
}

// Finally we drain the connection which waits for any pending
// messages (published or in a subscription) to be flushed.
await nc.drain();

console.log("Closed service connection to NATS...")
