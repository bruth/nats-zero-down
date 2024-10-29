FROM gradle:7.5.1-jdk8-jammy AS build

COPY --chown=gradle:gradle . /home/gradle/src
WORKDIR /home/gradle/src

RUN mkdir -p src/main/java/example
RUN mv *.java src/main/java/example/
RUN gradle clean uberJar --no-daemon 

FROM golang:1.22-alpine

RUN apk update && apk add git bash curl openjdk8

RUN go install github.com/nats-io/nats-server/v2@v2.10.22
RUN go install github.com/nats-io/natscli/nats@v0.1.5
RUN go install github.com/nats-io/nsc/v2@v2.10.0

COPY --from=build /home/gradle/src/build/libs/*.jar /app/example.jar
COPY main.sh main.sh

ENTRYPOINT ["bash"]
CMD ["main.sh"]
