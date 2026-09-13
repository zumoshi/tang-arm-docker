# syntax=docker/dockerfile:1.7
#
# Builds tang itself against the cached deps image (see Containerfile.deps
# and build-deps.yml) and assembles the final scratch image. This is the
# file that should change on ordinary iterations; it doesn't rebuild
# OpenSSL/jose/jansson/zlib/http_parser each time.

ARG TANG_VERSION=15

FROM ghcr.io/zumoshi/tang-arm-docker-deps:arm64 AS build
ARG TANG_VERSION

# tang - force a fully static link against the private static-only libdir
# baked into the deps image.
RUN curl -fL https://github.com/latchset/tang/archive/refs/tags/v${TANG_VERSION}.tar.gz | tar xz -C /tmp \
 && cd /tmp/tang-${TANG_VERSION} \
 && PKG_CONFIG_LIBDIR=/opt/staticlibs/pkgconfig CFLAGS=-static LDFLAGS=-static meson setup build --prefix=/out \
 && ninja -C build install \
 && strip /out/libexec/tangd \
 && file /out/libexec/tangd \
 && mkdir -p /out/db

FROM scratch
COPY --from=build /out/libexec/tangd /tangd
COPY --from=build /out/db /db
ENTRYPOINT ["/tangd", "-l", "-p", "9090", "/db"]
