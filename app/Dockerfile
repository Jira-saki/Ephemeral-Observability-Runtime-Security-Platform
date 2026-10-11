# Stage 1: Build binary
FROM golang:1.23-alpine AS builder

WORKDIR /src

RUN apk add --no-cache ca-certificates tzdata

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /bin/api-server .

# Stage 2: Minimal Distroless Runtime (no shell, no package manager)
FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /
COPY --from=builder /bin/api-server /api-server
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

USER 65532:65532
EXPOSE 8080

ENTRYPOINT ["/api-server"]
