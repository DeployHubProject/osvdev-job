FROM public.ecr.aws/amazonlinux/amazonlinux:2027.0.20261026.1-minimal AS builder

WORKDIR /app

RUN microdnf install -y golang git && \
    microdnf clean all

COPY . /app

RUN go mod tidy; \
    go build -o main .

FROM public.ecr.aws/amazonlinux/amazonlinux:2027.0.20261026.1-minimal

WORKDIR /app

COPY --from=builder /app/main .

ENV ARANGO_HOST=localhost
ENV ARANGO_USER=root
ENV ARANGO_PASS=rootpassword
ENV ARANGO_PORT=8529

# The Chainguard runtime image ran as non-root by default; Amazon Linux does not.
USER 65532:65532

EXPOSE 8080

ENTRYPOINT [ "/app/main" ]