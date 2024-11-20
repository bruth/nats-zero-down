FROM golang:1.19-alpine3.17 AS build

RUN apk update && apk add git bash curl jq

RUN go install github.com/nats-io/natscli/nats@latest
RUN go install github.com/nats-io/nats-server/v2@latest

WORKDIR /opt/app

COPY go.mod go.sum ./
RUN go mod download && go mod verify

COPY main.go ./
RUN go build -v -o /app .

FROM alpine

RUN apk update && apk add bash curl jq

COPY --from=build /go/bin/nats-server /usr/local/bin/
COPY --from=build /go/bin/nats /usr/local/bin/
COPY --from=build /app /app

COPY . ./

ENTRYPOINT ["bash"]

CMD ["main.sh"]
