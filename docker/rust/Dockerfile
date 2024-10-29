FROM rust:1.82-slim AS build

WORKDIR /opt/app

# Cache invalidation as Rust Cargo.toml refers main branch.
ARG CACHE_INVALIDATE="2022-12-29T13:26:05Z"

# Compile dependencies in one layer that can be reused across all examples.
COPY Cargo.toml .
RUN echo "fn main(){}" > main.rs && cargo build && rm main.rs && rm /opt/app/target/debug/app
COPY . .

RUN cargo update
RUN cargo build

FROM debian:bullseye-slim

COPY --from=build /opt/app/target/debug/app /app

CMD ["/app"]
