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

RUN curl -fL https://github.com/latchset/tang/archive/refs/tags/v${TANG_VERSION}.tar.gz | tar xz -C /tmp

# Build a private static-only library directory + hand-written jose.pc,
# rather than deleting the system .so files (curl and python/meson are
# themselves dynamically linked against libz/libssl/libcrypto, so removing
# those broke the toolchain). jose's real .pc only exposes -lcrypto/-lssl/
# -lz under a "--static" pkg-config query, which tang's plain
# dependency('jose', ...) call never makes, so those need to be listed
# unconditionally here too.
RUN mkdir -p /opt/staticlibs/pkgconfig \
 && cp /usr/lib/libjose.a /usr/lib/libjansson.a /usr/lib/libssl.a /usr/lib/libcrypto.a /usr/lib/libz.a /usr/lib/libhttp_parser.a /opt/staticlibs/ \
 && printf 'libdir=/opt/staticlibs\nincludedir=/usr/include\n\nName: jose\nDescription: static jose\nVersion: %s\nCflags: -I${includedir}\nLibs: -L${libdir} -ljose -ljansson -lssl -lcrypto -lz\n' "${JOSE_VERSION}" > /opt/staticlibs/pkgconfig/jose.pc

# tang - force a fully static link against the private static-only libdir
RUN cd /tmp/tang-${TANG_VERSION} \
 && PKG_CONFIG_LIBDIR=/opt/staticlibs/pkgconfig CFLAGS=-static LDFLAGS=-static meson setup build --prefix=/out \
 && ninja -C build install \
 && strip /out/libexec/tangd \
 && file /out/libexec/tangd \
 && mkdir -p /out/db

FROM scratch
COPY --from=build /out/libexec/tangd /tangd
COPY --from=build /out/db /db
ENTRYPOINT ["/tangd", "-l", "-p", "9090", "/db"]
