FROM golang:1.22.0-alpine AS builder

ARG version=0.0.0
ARG build_time=local
ARG gitsha=dirty

RUN apk add --no-cache git

WORKDIR /app

COPY go.mod go.sum ./

RUN go mod download

COPY . .

# https://stackoverflow.com/questions/36279253/go-compiled-binary-wont-run-in-an-alpine-docker-container-on-ubuntu-host
ENV CGO_ENABLED=0
RUN GOOS=linux GOARCH=amd64 go build -o /opt/server/server ./cmd/main


FROM alpine:3.19.0 as final

WORKDIR /opt/server

COPY --from=builder /opt/server .

ENTRYPOINT ["/opt/server/server"]