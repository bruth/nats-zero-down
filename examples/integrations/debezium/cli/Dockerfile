FROM golang:1.22-alpine AS build

RUN apk update && apk add git

RUN go install github.com/nats-io/nats-server/v2@v2.10.22
RUN go install github.com/nats-io/natscli/nats@v0.1.5

FROM alpine

RUN apk add bash curl postgresql-client jq

COPY --from=build /go/bin/nats-server /usr/local/bin/
COPY --from=build /go/bin/nats /usr/local/bin/

COPY . .

ENTRYPOINT ["bash"]

CMD ["main.sh"]
