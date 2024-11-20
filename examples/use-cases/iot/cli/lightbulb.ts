import {
  signal
} from "https://deno.land/std@0.171.0/signal/mod.ts";

import {
  connect
} from 'npm:mqtt';

// Get the passed NATS_URL or fallback to the default. This can be
// a comma-separated string.
const url = Deno.env.get("MQTT_URL");
const username = Deno.env.get("IOT_USERNAME");
const password = Deno.env.get("IOT_PASSWORD");

console.log(`Connecting to NATS via MQTT: ${username} -> ${url}...`)

// Create a client connection to an available NATS server.
const mc = connect(url, {
  username: username,
  password: password,
});

// Initialize the default state to be off.
let state = 0;

mc.on('connect', () => {
  console.log('Connected to NATS via MQTT...')
  // Indicate the device is connected.
  mc.publish(`iot/${username}/events/connected`);

  // Subscribe to commands to change behavior.
  mc.subscribe(`iot/${username}/commands/#`);

  mc.on('message', (topic: string) => {
    console.log(`Received by ${username}... ${topic}`)
    switch (topic) {
      case `iot/${username}/commands/on`:
        if (state === 0) {
          state = 1
          mc.publish(`iot/${username}/events/on`)
        }
        break;

      case `iot/${username}/commands/off`:
        if (state === 1) {
          state = 0
          mc.publish(`iot/${username}/events/off`)
        }
        break;

      default:
        console.log(`unknown commands: ${topic}`)
    }
  })
});

// Block until an interrupt occurs.
const sig = signal("SIGINT");
for await (const s of sig) {
  console.log('Closing MQTT connection...')
  // Indicate the device is disconnected.
  mc.publish(`iot/${username}/events/disconnected`);
  mc.end();
  break;
}
