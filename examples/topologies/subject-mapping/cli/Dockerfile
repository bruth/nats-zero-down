FROM natsio/nats-box:0.13.2

# Copy nats-server from source image.
COPY --from=nats:2.9.6-alpine /usr/local/bin/nats-server /usr/local/bin/

COPY . .

CMD ["main.sh"]

