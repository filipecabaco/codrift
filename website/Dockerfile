ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20250520-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS build

RUN apt-get update -y \
  && apt-get install -y build-essential git curl ca-certificates \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

COPY config config
RUN mix deps.compile

COPY assets assets
COPY priv priv
COPY lib lib

RUN mix compile
RUN mix tailwind.install --if-missing
RUN mix assets.build
RUN mix release

FROM ${RUNNER_IMAGE} AS run

RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV MIX_ENV=prod
ENV HOME=/app

WORKDIR /app

RUN useradd --create-home --shell /bin/bash app && chown app:app /app
USER app

COPY --from=build --chown=app:app /app/_build/prod/rel/website ./
COPY --from=build --chown=app:app /app/priv ./priv

EXPOSE 4001

CMD ["bin/website", "start"]
