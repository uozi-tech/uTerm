FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /uterm-relay ./cmd/uterm-relay
# 0700: the directory holds the member private key. A new named volume copies this mode.
RUN mkdir -p /data && chown 65532:65532 /data && chmod 700 /data

FROM scratch
COPY --from=build /uterm-relay /uterm-relay
COPY --from=build --chown=65532:65532 /data /data
USER 65532:65532
EXPOSE 47310/tcp 47310/udp
VOLUME /data
ENTRYPOINT ["/uterm-relay"]
