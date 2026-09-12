# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.21
ARG MUSL_CROSS_URL=https://musl.cc/aarch64-linux-musl-cross.tgz
ARG OPENSSL_VERSION=3.3.2
ARG ZLIB_VERSION=1.3.1
ARG JANSSON_VERSION=2.14
ARG JOSE_VERSION=14
ARG HTTP_PARSER_VERSION=2.9.4
ARG TANG_VERSION=15

FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS build
ARG MUSL_CROSS_URL
ARG OPENSSL_VERSION
ARG ZLIB_VERSION
ARG JANSSON_VERSION
ARG JOSE_VERSION
ARG HTTP_PARSER_VERSION
ARG TANG_VERSION

RUN apk add --no-cache build-base curl meson ninja pkgconf perl linux-headers automake autoconf libtool

RUN curl -fL "$MUSL_CROSS_URL" -o /tmp/cross.tgz \
 && mkdir -p /opt/cross \
 && tar -xzf /tmp/cross.tgz -C /opt/cross --strip-components=1

ENV PATH=/opt/cross/bin:$PATH \
    CROSS=aarch64-linux-musl \
    SYSROOT=/opt/sysroot \
    PKG_CONFIG_LIBDIR=/opt/sysroot/lib/pkgconfig \
    PKG_CONFIG_PATH=/opt/sysroot/lib/pkgconfig
RUN mkdir -p $SYSROOT

# zlib
RUN curl -fL https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz | tar xz -C /tmp \
 && cd /tmp/zlib-${ZLIB_VERSION} \
 && CC=${CROSS}-gcc AR=${CROSS}-ar ./configure --prefix=$SYSROOT --static \
 && make -j"$(nproc)" && make install

# openssl
RUN curl -fL https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz | tar xz -C /tmp \
 && cd /tmp/openssl-${OPENSSL_VERSION} \
 && ./Configure linux-aarch64 no-shared no-tests \
      --cross-compile-prefix=${CROSS}- \
      --prefix=$SYSROOT --openssldir=$SYSROOT/ssl \
 && make -j"$(nproc)" && make install_sw

# jansson
RUN curl -fL https://github.com/akheron/jansson/releases/download/v${JANSSON_VERSION}/jansson-${JANSSON_VERSION}.tar.gz | tar xz -C /tmp \
 && cd /tmp/jansson-${JANSSON_VERSION} \
 && ./configure --host=${CROSS} --prefix=$SYSROOT --enable-static --disable-shared \
 && make -j"$(nproc)" && make install

# http_parser (tang's fallback HTTP lib; simpler to vendor than llhttp's codegen step)
RUN curl -fL https://github.com/nodejs/http-parser/archive/refs/tags/v${HTTP_PARSER_VERSION}.tar.gz | tar xz -C /tmp \
 && cd /tmp/http-parser-${HTTP_PARSER_VERSION} \
 && ${CROSS}-gcc -c http_parser.c -o http_parser.o \
 && ${CROSS}-ar rcs libhttp_parser.a http_parser.o \
 && cp libhttp_parser.a $SYSROOT/lib/ \
 && cp http_parser.h $SYSROOT/include/

COPY cross-file.txt /tmp/cross-file.txt

# jose
RUN curl -fL https://github.com/latchset/jose/archive/refs/tags/v${JOSE_VERSION}.tar.gz | tar xz -C /tmp \
 && cd /tmp/jose-${JOSE_VERSION} \
 && meson setup build --cross-file /tmp/cross-file.txt --prefix=$SYSROOT \
      --default-library=static -Dtests=false \
 && ninja -C build install

# tang
RUN curl -fL https://github.com/latchset/tang/archive/refs/tags/v${TANG_VERSION}.tar.gz | tar xz -C /tmp \
 && cd /tmp/tang-${TANG_VERSION} \
 && meson setup build --cross-file /tmp/cross-file.txt --prefix=/out \
 && ninja -C build install \
 && ${CROSS}-strip /out/libexec/tangd

FROM scratch
COPY --from=build /out/libexec/tangd /tangd
ENTRYPOINT ["/tangd", "-l", "-p", "9090"]
