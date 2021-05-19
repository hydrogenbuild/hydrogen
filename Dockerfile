FROM arm64v8/erlang:22.3.2-alpine as builder

RUN apk add --no-cache --update \
    git tar build-base linux-headers autoconf automake libtool pkgconfig \
    dbus-dev bzip2 bison flex gmp-dev cmake lz4 libsodium-dev openssl-dev \
    sed wget curl

# Install Rust toolchain
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

WORKDIR /usr/src/miner

ENV CC=gcc CXX=g++ CFLAGS="-U__sun__" \
    ERLANG_ROCKSDB_OPTS="-DWITH_BUNDLE_SNAPPY=ON -DWITH_BUNDLE_LZ4=ON" \
    ERL_COMPILER_OPTIONS="[deterministic]" \
    PATH="/root/.cargo/bin:$PATH" \
    RUSTFLAGS="-C target-feature=-crt-static"

# Add our code
ADD . /usr/src/miner/

RUN ./rebar3 as docker tar

RUN mkdir -p /opt/docker
RUN tar -zxvf _build/docker/rel/*/*.tar.gz -C /opt/docker
RUN mkdir -p /opt/docker/update
RUN wget https://github.com/helium/blockchain-api/raw/master/priv/prod/genesis
RUN cp genesis /opt/docker/update/genesis

FROM arm64v8/erlang:22.3.2-alpine as runner

RUN apk add --no-cache --update ncurses dbus gmp libsodium gcc
RUN ulimit -n 64000

WORKDIR /opt/miner

ENV COOKIE=miner \
    # Write files generated during startup to /tmp
    RELX_OUT_FILE_PATH=/tmp \
    # add miner to path, for easy interactions
    PATH=$PATH:/opt/miner/bin

COPY --from=builder /opt/docker /opt/miner

ENTRYPOINT ["/opt/miner/bin/miner"]
CMD ["foreground"]

ENV COOKIE=miner \
    # Write files generated during startup to /tmp
    RELX_OUT_FILE_PATH=/tmp \
    # add miner to path, for easy interactions
    PATH=$PATH:/opt/miner/bin

COPY --from=builder /opt/docker /opt/miner

ENTRYPOINT ["/opt/miner/bin/miner"]
CMD ["foreground"]

RUN [ “cross-build-end” ]
