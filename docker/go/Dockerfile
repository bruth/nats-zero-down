FROM golang:1.22.8-alpine3.20 AS build

WORKDIR /opt/app

COPY go.mod go.sum ./
RUN go mod download && go mod verify

COPY . ./
RUN go build -v -o /app ./...

FROM alpine

COPY --from=build /app /app

CMD ["/app"]

