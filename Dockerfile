ARG BUILDER_IMAGE=hexpm/elixir:1.14.5-erlang-25.3.2.4-debian-bullseye-20230612
ARG NODE_VERSION=20.20.2
ARG NODE_SHA256=df770b2a6f130ed8627c9782c988fda9669fa23898329a61a871e32f965e007d
ARG SOURCE_COMMIT

FROM ${BUILDER_IMAGE} AS builder

ARG NODE_VERSION
ARG NODE_SHA256

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update -q && apt-get --no-install-recommends install -y apt-utils ca-certificates build-essential libtool autoconf curl git

RUN NODE_TARBALL=node-v${NODE_VERSION}-linux-x64.tar.xz && \
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

FROM debian:bullseye-slim
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE=C.UTF-8
RUN apt-get update -q && apt-get --no-install-recommends install -y git-core libssl1.1 curl apt-utils ca-certificates

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
