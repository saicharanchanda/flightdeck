# One Dockerfile for every service. Build from the repo root so the shared
# libs/svckit module is in the context:
#   docker build -f build/Dockerfile --build-arg SERVICE=gateway .

FROM golang:1.27.2 AS build
ARG SERVICE
WORKDIR /src

# Module files first so dependency downloads cache independently of code.
COPY libs/svckit/go.mod libs/svckit/go.sum libs/svckit/
COPY apps/${SERVICE}/go.mod apps/${SERVICE}/go.sum apps/${SERVICE}/
RUN cd apps/${SERVICE} && go mod download

COPY libs/ libs/
COPY apps/${SERVICE}/ apps/${SERVICE}/
RUN cd apps/${SERVICE} && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
