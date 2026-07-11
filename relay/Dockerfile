# syntax=docker/dockerfile:1

# ---- build stage ----
FROM golang:1.25 AS build
WORKDIR /src

# Resolve and cache modules first for faster rebuilds.
COPY go.mod go.sum ./
RUN go mod download

# Build a fully static binary: no cgo, trimmed paths, stripped symbols.
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/relayd ./cmd/relayd

# ---- runtime stage ----
# scratch: nothing but the static binary. Minimal attack surface for a service
# that only speaks websockets and terminates no secrets.
FROM scratch

# Run as a non-root numeric UID/GID (nobody). scratch has no /etc/passwd.
USER 65534:65534

COPY --from=build /out/relayd /relayd

# Plain HTTP by default; terminate TLS at a reverse proxy (see README) or pass
# -cert/-key pointing at mounted files to serve TLS directly.
EXPOSE 8080
ENTRYPOINT ["/relayd"]
CMD ["-addr", ":8080"]
