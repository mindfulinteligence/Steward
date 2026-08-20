# syntax=docker/dockerfile:1

# --- Dev image (local docker-compose.yml) ---
FROM elixir:1.17-alpine AS dev

RUN apk add --no-cache build-base git curl sqlite-dev

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/root/.mix \
    HEX_HTTP_TIMEOUT=120 mix deps.get && mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY assets assets

RUN mix compile

ENV MIX_ENV=dev
EXPOSE 4001

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f "http://localhost:${PORT:-4001}/mcp/health" || exit 1

CMD ["sh", "-c", "mix ecto.migrate && mix phx.server"]

# --- Release build ---
FROM elixir:1.17-alpine AS build

RUN apk add --no-cache build-base git sqlite-dev

WORKDIR /app

ENV MIX_ENV=prod

ARG REPO_ADAPTER=postgres
ENV REPO_ADAPTER=${REPO_ADAPTER}

# ponytail: compile-only dummy; runtime SECRET_KEY_BASE comes from compose/env
ARG SECRET_KEY_BASE=build_time_secret_key_base_not_used_at_runtime

ARG PGPASSWORD=build_time_not_used_at_runtime

RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
# Do not cache _build — stale sqlite vs postgres Acs.Repo beams stick across rebuilds.
RUN --mount=type=cache,target=/root/.mix \
    HEX_HTTP_CONCURRENCY=8 HEX_HTTP_TIMEOUT=120 \
    mix deps.get --only prod && mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY assets assets

# Include REPO_ADAPTER in the RUN so BuildKit cannot reuse a sqlite compile layer.
RUN echo "REPO_ADAPTER=${REPO_ADAPTER}" \
    && test -n "${REPO_ADAPTER}" \
    && export COOKIE_SIGNING_SALT=$(printf '%s' "$SECRET_KEY_BASE" | sha256sum | awk '{print $1}' | cut -c1-16) \
    && mix compile \
    && mix assets.deploy \
    && mix release \
    && (strings /app/_build/prod/lib/steward_acs/ebin/Elixir.Acs.Repo.beam | grep -q 'Ecto.Adapters.Postgres' \
        || (echo "ERROR: Acs.Repo beam is not Postgres — REPO_ADAPTER=${REPO_ADAPTER}" >&2; exit 1))

# --- Production runtime ---
FROM alpine:3.22 AS release

ARG GIT_SHA=unknown
ARG GIT_DIRTY=clean
LABEL org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.dirty="${GIT_DIRTY}"

RUN apk add --no-cache libstdc++ openssl ncurses-libs curl sqlite-libs libgcc su-exec inotify-tools

RUN addgroup -g 1000 -S acs && adduser -u 1000 -S acs -G acs

WORKDIR /app

COPY --from=build /app/_build/prod/rel/steward_acs ./
COPY docker/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && chown -R acs:acs /app

ENV HOME=/app \
    MIX_ENV=prod \
    PORT=4001

EXPOSE 4001

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f "http://localhost:${PORT}/mcp/health" || exit 1

ENTRYPOINT ["/entrypoint.sh"]
