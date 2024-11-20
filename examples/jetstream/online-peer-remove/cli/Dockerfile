FROM golang:1.19-alpine3.17 AS build

RUN go install github.com/nats-io/natscli/nats@allow-online-peer-remove
RUN go install github.com/nats-io/nats-server/v2@main

FROM natsio/nats-box:0.13.2

RUN apk add bash curl

COPY --from=build /go/bin/nats-server /usr/local/bin/
COPY --from=build /go/bin/nats /usr/local/bin/

COPY . .

ENTRYPOINT ["bash"]

CMD ["main.sh"]
