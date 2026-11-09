# syntax=docker/dockerfile:1

# ---------- Stage 1: build ----------
# The full ruby image ships gcc/make and the MySQL headers (default-libmysqlclient-dev)
# needed to compile native gems such as mysql2.
FROM ruby:3.3 AS build

WORKDIR /rails

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test

# Install gems first so this layer is cached until Gemfile/Gemfile.lock change.
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Copy the application and precompile bootsnap cache for faster boot.
COPY . .
RUN bundle exec bootsnap precompile app/ lib/

# ---------- Stage 2: runtime ----------
# Slim image: no compilers, only the libraries needed at runtime.
FROM ruby:3.3-slim AS runtime

WORKDIR /rails

# libmariadb3 provides libmysqlclient.so, which the compiled mysql2 gem links against.
# curl is used by the container healthcheck.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libmariadb3 curl && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    PORT=3000 \
    RAILS_LOG_TO_STDOUT=1

# Non-root user that will own and run the app.
RUN groupadd --system --gid 1000 rails && \
    useradd --system --uid 1000 --gid rails --create-home --shell /bin/bash rails

# Copy installed gems and the app from the build stage.
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build --chown=rails:rails /rails /rails

USER 1000:1000

EXPOSE 3000

# Create/migrate the database, then run Puma in the foreground.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
