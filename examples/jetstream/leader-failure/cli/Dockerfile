FROM natsio/nats-box:0.13.2

RUN apk add bash curl

COPY --from=nats:2.9.5 /nats-server /usr/local/bin/

COPY . .

ENTRYPOINT ["bash"]

CMD ["main.sh"]

