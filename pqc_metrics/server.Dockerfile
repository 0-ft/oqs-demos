# Multi-stage build: First the full builder image:

# define the liboqs tag to be used
ARG LIBOQS_TAG=main

# define the oqsprovider tag to be used
ARG OQSPROVIDER_TAG=main

# define the Curl version to be baked in
ARG CURL_VERSION=7.81.0

# Default location where all binaries wind up:
ARG INSTALLDIR=/opt/oqssa

# liboqs build type variant; maximum portability of image:
ARG LIBOQS_BUILD_DEFINES="-DOQS_DIST_BUILD=ON"

# Default root CA signature algorithm; can be set to any listed at https://github.com/open-quantum-safe/oqs-provider#algorithms
ARG SIG_ALG="dilithium3"

# Default KEM algorithms; can be set to any listed at https://github.com/open-quantum-safe/oqs-provider#algorithms
ARG DEFAULT_GROUPS="x25519:x448:kyber512:p256_kyber512:kyber768:p384_kyber768:kyber1024:p521_kyber1024"

# Define the degree of parallelism when building the image; leave the number away only if you know what you are doing
ARG MAKE_DEFINES="-j 4"


FROM alpine:3.11 AS builder
# Take in all global args
ARG LIBOQS_TAG
ARG OQSPROVIDER_TAG
ARG CURL_VERSION
ARG INSTALLDIR
ARG LIBOQS_BUILD_DEFINES
ARG SIG_ALG
ARG DEFAULT_GROUPS
ARG MAKE_DEFINES

LABEL version="4"

ENV DEBIAN_FRONTEND noninteractive

RUN apk update && apk upgrade

# Get all software packages required for builing all components:
RUN apk add --no-cache build-base linux-headers \
    libtool automake autoconf cmake ninja \
    make \
    openssl openssl-dev \
    git wget bash

# get all sources
WORKDIR /opt
RUN git clone --depth 1 --branch ${LIBOQS_TAG} https://github.com/open-quantum-safe/liboqs && \
    git clone --depth 1 --branch master https://github.com/openssl/openssl.git && \
    git clone --depth 1 --branch ${OQSPROVIDER_TAG} https://github.com/open-quantum-safe/oqs-provider.git && \
    wget https://curl.haxx.se/download/curl-${CURL_VERSION}.tar.gz && tar -zxvf curl-${CURL_VERSION}.tar.gz;

# build liboqs
WORKDIR /opt/liboqs
RUN mkdir build && cd build && cmake -G"Ninja" .. ${LIBOQS_BUILD_DEFINES} -DCMAKE_INSTALL_PREFIX=${INSTALLDIR} && ninja install

# build OpenSSL3
WORKDIR /opt/openssl
RUN LDFLAGS="-Wl,-rpath -Wl,${INSTALLDIR}/lib64" ./config shared --prefix=${INSTALLDIR} && \
    make ${MAKE_DEFINES} && make install_sw install_ssldirs;

# set path to use 'new' openssl. Dyn libs have been properly linked in to match
ENV PATH="${INSTALLDIR}/bin:${PATH}"

# build & install provider (and activate by default)
WORKDIR /opt/oqs-provider
RUN ln -s ../openssl .
RUN cmake -DOPENSSL_ROOT_DIR=${INSTALLDIR} -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=${INSTALLDIR} -S . -B _build
RUN cmake --build _build 
RUN cp _build/lib/oqsprovider.so ${INSTALLDIR}/lib64/ossl-modules
RUN sed -i "s/default = default_sect/default = default_sect\noqsprovider = oqsprovider_sect/g" /opt/oqssa/ssl/openssl.cnf
RUN sed -i "s/\[default_sect\]/\[default_sect\]\nactivate = 1\n\[oqsprovider_sect\]\nactivate = 1\n/g" /opt/oqssa/ssl/openssl.cnf
RUN sed -i "s/providers = provider_sect/providers = provider_sect\nssl_conf = ssl_sect\n\n\[ssl_sect\]\nsystem_default = system_default_sect\n\n\[system_default_sect\]\nGroups = \$ENV\:\:DEFAULT_GROUPS\n/g" /opt/oqssa/ssl/openssl.cnf
RUN sed -i "s/\# Use this in order to automatically load providers/\# Set default KEM groups if not set via environment variable\nKDEFAULT_GROUPS = $DEFAULT_GROUPS\n\n# Use this in order to automatically load providers/g" /opt/oqssa/ssl/openssl.cnf
RUN sed -i "s/HOME\t\t\t= ./HOME\t\t= .\nDEFAULT_GROUPS\t= ${DEFAULT_GROUPS}/g" /opt/oqssa/ssl/openssl.cnf

# generate certificates for openssl s_server, which is what we will test curl against
ENV OPENSSL=${INSTALLDIR}/bin/openssl
ENV OPENSSL_CNF=${INSTALLDIR}/ssl/openssl.cnf

# build curl
WORKDIR /opt/curl-${CURL_VERSION}

# For curl debugging enable it by adding the line below to the configure command:
#                    --enable-debug \

RUN env LDFLAGS=-Wl,-R${INSTALLDIR}/lib64  \
    ./configure --prefix=${INSTALLDIR} \
    # --with-ca-bundle=${INSTALLDIR}/oqs-bundle.pem \
    --with-ssl=${INSTALLDIR} && \
    make ${MAKE_DEFINES} && make install

# RUN mv oqs-bundle.pem ${INSTALLDIR};

FROM builder AS with_certificates
ARG INSTALLDIR
ARG SIG_ALG

COPY --from=builder ${INSTALLDIR} ${INSTALLDIR}

# Download current test.openquantumsafe.org test CA cert
WORKDIR ${INSTALLDIR}

# Download and integrate LetsEncrypt Root CA to CA bundle
RUN wget https://letsencrypt.org/certs/isrgrootx1.pem -O letsencrypt-ca.pem

# generate CA key and cert
RUN set -x; \
    ${OPENSSL} req -x509 -new -newkey ${SIG_ALG} -keyout CA.key -out custom-ca.pem -nodes -subj "/CN=oqstest CA" -days 365 -config ${OPENSSL_CNF}

RUN wget https://test.openquantumsafe.org/CA.crt -O oqs-testca.pem
RUN cat custom-ca.pem oqs-testca.pem letsencrypt-ca.pem >> oqs-bundle.pem

# Add both CA certificates to the system collection
RUN cat oqs-bundle.pem >> /etc/ssl/certs/ca-certificates.crt

# FROM with_certificates AS server

# COPY --from=with_certificates ${INSTALLDIR} ${INSTALLDIR}
# COPY --from=with_certificates /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

# WORKDIR /

# COPY serverstart.sh ${INSTALLDIR}/bin

# CMD ["serverstart.sh"]

# # set path to use 'new' openssl & curl. Dyn libs have been properly linked in to match
# ENV PATH="${INSTALLDIR}/bin:${PATH}"

# # generate certificates for openssl s_server, which is what we will test curl against
# ENV OPENSSL=${INSTALLDIR}/bin/openssl
# ENV OPENSSL_CNF=${INSTALLDIR}/ssl/openssl.cnf

# WORKDIR ${INSTALLDIR}/bin

# # generate server CSR using pre-set CA.key and cert
# # and generate server cert
# RUN set -x && mkdir /opt/test; \
#     ${OPENSSL} req -new -newkey ${SIG_ALG} -keyout /opt/test/server.key -out /opt/test/server.csr -nodes -subj "/CN=localhost" -config ${OPENSSL_CNF}; \
#     ${OPENSSL} x509 -req -in /opt/test/server.csr -out /opt/test/server.crt -CA CA.crt -CAkey CA.key -CAcreateserial -days 365;

# COPY serverstart.sh ${INSTALLDIR}/bin
# COPY perftest.sh ${INSTALLDIR}/bin

# WORKDIR ${INSTALLDIR}

# FROM server AS perf_test
# ARG INSTALLDIR

# WORKDIR /

# # Improve size some more: liboqs.a not needed during operation
# RUN rm ${INSTALLDIR}/lib/liboqs*

# # Enable a normal user to create new server keys off set CA
# RUN addgroup -g 1000 -S oqs && adduser --uid 1000 -S oqs -G oqs && chown -R oqs.oqs /opt/test && chmod go+r ${INSTALLDIR}/bin/CA.key && chmod go+w ${INSTALLDIR}/bin/CA.srl

# USER oqs
# CMD ["serverstart.sh"]
# STOPSIGNAL SIGTERM
