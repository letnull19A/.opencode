# Dockerfile.go — vendor-lock-free, layered multi-stage for Go
# Источник: .opencode/scripts/docker-pack/templates/Dockerfile.go
ARG GO_VERSION=1.22

FROM golang:${GO_VERSION}-alpine AS builder
WORKDIR /src
RUN apk add --no-cache git ca-certificates
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/app .

FROM alpine:3.19 AS runner
WORKDIR /app
RUN addgroup -S app && adduser -S app -G app && apk add --no-cache ca-certificates
COPY --from=builder /out/app ./app
USER app
EXPOSE 8080
CMD ["./app"]
