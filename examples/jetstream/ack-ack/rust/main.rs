use std::{env};
use async_nats::jetstream;
use futures::StreamExt;

#[tokio::main]
async fn main() -> Result<(), async_nats::Error> {
    let nats_url = env::var("NATS_URL").unwrap_or_else(|_| "nats://localhost:4222".to_string());

    let client = async_nats::connect(nats_url).await?;
    let jetstream = jetstream::new(client);

    let stream = jetstream
        .create_stream(jetstream::stream::Config {
            name: "EVENTS".to_string(),
            subjects: vec!["event.foo".to_string()],
            ..Default::default()
        })
        .await?;

    let _ = jetstream.publish("event.foo", "1".into()).await;
    let _ = jetstream.publish("event.foo", "2".into()).await;

    let mut consumer = stream
        .create_consumer(async_nats::jetstream::consumer::pull::Config { ..Default::default()})
        .await?;

    let ci = consumer.info().await?;
    println!("Consumer 1");
    println!("  Start\n    # pending messages: {}\n    # messages with ack pending: {}", ci.num_pending, ci.num_ack_pending);

    let message = consumer.fetch().max_messages(1).messages().await?.next().await.unwrap()?;
    let ci = consumer.info().await?;
    println!("  After received but before ack\n    # pending messages: {}\n    # messages with ack pending: {}", ci.num_pending, ci.num_ack_pending);

    message.ack().await?;

    let ci = consumer.info().await?;
    println!("  After ack\n    # pending messages: {}\n    # messages with ack pending: {}", ci.num_pending, ci.num_ack_pending);

    // Consumer 2 will use double_ack()
    let stream = jetstream.get_stream("EVENTS".to_string()).await?;
    let mut consumer = stream
        .create_consumer(async_nats::jetstream::consumer::pull::Config { ..Default::default()})
        .await?;

    let ci = consumer.info().await?;
    println!("Consumer 2");
    println!("  Start\n    # pending messages: {}\n    # messages with ack pending: {}", ci.num_pending, ci.num_ack_pending);

    let message = consumer.fetch().max_messages(1).messages().await?.next().await.unwrap()?;
    let ci = consumer.info().await?;
    println!("  After received but before ack\n    # pending messages: {}\n    # messages with ack pending: {}", ci.num_pending, ci.num_ack_pending);

    message.double_ack().await?;

    let ci = consumer.info().await?;
    println!("  After ack\n    # pending messages: {}\n    # messages with ack pending: {}", ci.num_pending, ci.num_ack_pending);

    Ok(())
}
