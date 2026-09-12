# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.21
ARG JOSE_VERSION=14
ARG HTTP_PARSER_VERSION=2.9.4
ARG TANG_VERSION=15

FROM alpine:${ALPINE_VERSION} AS build
ARG JOSE_VERSION
ARG HTTP_PARSER_VERSION
ARG TANG_VERSION

RUN apk add --no-cache \
    build-base curl meson ninja pkgconf \
    jansson-dev jansson-static \
    openssl-dev openssl-libs-static \
    zlib-dev zlib-static

# http_parser (tang's fallback HTTP lib; simpler to vendor than llhttp's codegen step)
RUN curl -fL https://github.com/nodejs/http-parser/archive/refs/tags/v${HTTP_PARSER_VERSION}.tar.gz | tar xz -C /tmp \
 && cd /tmp/http-parser-${HTTP_PARSER_VERSION} \
 && gcc -c http_parser.c -o http_parser.o \
 && ar rcs libhttp_parser.a http_parser.o \
 && cp libhttp_parser.a /usr/lib/ \
 && cp http_parser.h /usr/include/

# jose - upstream meson.build always builds a shared library regardless of
# --default-library, so build it normally, then archive its already-compiled
# objects into a static .a ourselves for tang's fully-static link.
RUN curl -fL https://github.com/latchset/jose/archive/refs/tags/v${JOSE_VERSION}.tar.gz | tar xz -C /tmp \
 && cd /tmp/jose-${JOSE_VERSION} \
 && meson setup build --prefix=/usr \
 && ninja -C build install \
 && ar rcs /usr/lib/libjose.a build/lib/libjose.so.*.p/*.c.o

# Force the linker below to have no dynamic alternative: drop every .so we
# just installed, keeping only the .a archives (ours for jose, apk's for
# jansson/openssl/zlib). meson otherwise resolves these to absolute .so
# paths via pkg-config even with LDFLAGS=-static.
RUN rm -f /usr/lib/libjose.so* /usr/lib/libjansson.so* /usr/lib/libssl.so* /usr/lib/libcrypto.so* /usr/lib/libz.so*

# tang - force a fully static link (libjose.a we just built, plus the
# -static apk packages for jansson/openssl/zlib, plus libhttp_parser.a)
RUN curl -fL https://github.com/latchset/tang/archive/refs/tags/v${TANG_VERSION}.tar.gz | tar xz -C /tmp \
 && cd /tmp/tang-${TANG_VERSION} \
 && CFLAGS=-static LDFLAGS=-static meson setup build --prefix=/out \
 && ninja -C build install \
 && strip /out/libexec/tangd \
 && file /out/libexec/tangd

FROM scratch
COPY --from=build /out/libexec/tangd /tangd
ENTRYPOINT ["/tangd", "-l", "-p", "9090"]
