FROM golang:1.19-alpine3.17 AS build

RUN apk update && apk add git

RUN go install github.com/nats-io/nats-server/v2@v2.9.15
RUN go install github.com/nats-io/natscli/nats@main
RUN go install github.com/nats-io/nsc/v2@v2.7.8

FROM alpine:3.17

RUN apk add bash curl

COPY --from=build /go/bin/nats-server /usr/local/bin/
COPY --from=build /go/bin/nats /usr/local/bin/
COPY --from=build /go/bin/nsc /usr/local/bin/

WORKDIR /app

COPY . .

ENTRYPOINT ["bash"]

CMD ["main.sh"]
