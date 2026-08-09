FROM ruby:4.0.6-slim AS build

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test

WORKDIR /app

RUN apt-get update -qq \
 && apt-get install --no-install-recommends -y build-essential \
 && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
RUN bundle install && rm -rf "${BUNDLE_PATH}"/ruby/*/cache

# ---------------------------------------------------------------------------

FROM ruby:4.0.6-slim

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    RUBY_YJIT_ENABLE=1 \
    PORT=8080 \
    TZ=Asia/Tokyo

WORKDIR /app

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY . .

# rootfs は使い捨て。記憶は /data の volume だけにある。
# 非 root で走る。身体は壊れてよいが、外へは出られない。
RUN groupadd --system --gid 1000 creature \
 && useradd creature --uid 1000 --gid 1000 --create-home --shell /bin/false \
 && mkdir -p /data \
 && chown -R creature:creature /app /data

USER creature:creature

EXPOSE 8080
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
