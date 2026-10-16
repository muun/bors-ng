ARG BUILDER_IMAGE=hexpm/elixir:1.14.5-erlang-26.0.2-debian-bookworm-20260610
ARG NODE_VERSION=20.20.2
ARG NODE_SHA256_amd64=df770b2a6f130ed8627c9782c988fda9669fa23898329a61a871e32f965e007d
ARG NODE_SHA256_arm64=73093db209e4e9e09dd7d15a47aeaab1b74833830df03efa5f942a1122c5fa71
ARG SOURCE_COMMIT

FROM ${BUILDER_IMAGE} AS builder

ARG TARGETARCH
ARG NODE_VERSION
ARG NODE_SHA256_amd64
ARG NODE_SHA256_arm64

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update -q && apt-get --no-install-recommends install -y apt-utils ca-certificates build-essential libtool autoconf curl git

RUN case "${TARGETARCH}" in \
      amd64) NODE_ARCH=x64;   NODE_SHA256=${NODE_SHA256_amd64} ;; \
      arm64) NODE_ARCH=arm64; NODE_SHA256=${NODE_SHA256_arm64} ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    NODE_TARBALL=node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz && \
    curl -fsSLO https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL} && \
    echo "${NODE_SHA256}  ${NODE_TARBALL}" | sha256sum -c - && \
    tar -xJf ${NODE_TARBALL} -C /usr/local --strip-components=1 --no-same-owner && \
    rm ${NODE_TARBALL}

RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix hex.info

WORKDIR /src
ADD ./ /src/

# Set default environment for building
ENV ALLOW_PRIVATE_REPOS=true
ENV MIX_ENV=prod

RUN mix deps.get
RUN cd /src/ && npm install && npm run deploy
RUN mix phx.digest
RUN mix distillery.release --env=$MIX_ENV

# Make the git HEAD available to the released app
RUN if [ -d .git ]; then \
        mkdir /src/_build/prod/rel/bors/.git && \
        git rev-parse --short HEAD > /src/_build/prod/rel/bors/.git/HEAD; \
    elif [ -n ${SOURCE_COMMIT} ]; then \
        mkdir /src/_build/prod/rel/bors/.git && \
        echo ${SOURCE_COMMIT} > /src/_build/prod/rel/bors/.git/HEAD; \
    fi

####

FROM debian:bookworm-slim
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE=C.UTF-8
RUN apt-get update -q && apt-get --no-install-recommends install -y git-core libssl3 curl apt-utils ca-certificates

ADD ./script/docker-entrypoint /usr/local/bin/bors-ng-entrypoint
COPY --from=builder /src/_build/prod/rel/ /app/

RUN curl -Ls https://github.com/bors-ng/dockerize/releases/download/v0.7.12/dockerize-linux-amd64-v0.7.12.tar.gz | \
    tar xzv -C /usr/local/bin && \
    /app/bors/bin/bors describe

ENV PORT=4000
ENV DATABASE_AUTO_MIGRATE=true
ENV ALLOW_PRIVATE_REPOS=true

WORKDIR /app
ENTRYPOINT ["/usr/local/bin/bors-ng-entrypoint"]
CMD ["./bors/bin/bors", "foreground"]

EXPOSE 4000
