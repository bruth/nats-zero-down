FROM natsio/nats-box:0.12.0

ADD https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 /usr/local/bin/jq
RUN chmod +x /usr/local/bin/jq

# Copy nats-server from source image.
COPY --from=nats:2.8.4-alpine /usr/local/bin/nats-server /usr/local/bin/

COPY . .

CMD ["main.sh"]
