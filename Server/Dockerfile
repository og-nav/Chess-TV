# Build context is the repository root. Only these three source packages enter the image.
# swift:6.2-noble provides Ubuntu 24.04 and supplies Swift's runtime.
FROM swift:6.2-noble AS build
WORKDIR /src
COPY Packages/ChessCore Packages/ChessCore
COPY Packages/FollowKit Packages/FollowKit
COPY Server/follow-server Server/follow-server
RUN swift build --package-path Server/follow-server -c release -j 2 \
    && mkdir /out && cp Server/follow-server/.build/release/follow-server /out/follow-server

# Keeping the matching official image avoids missing Foundation/Swift shared libraries.
FROM swift:6.2-noble AS runtime
RUN groupadd --system --gid 10001 follow \
    && useradd --system --uid 10001 --gid follow --home /var/lib/follow-server follow \
    && mkdir -p /var/lib/follow-server && chown follow:follow /var/lib/follow-server
COPY --from=build /out/follow-server /usr/local/bin/follow-server
ENV FOLLOW_HOST=0.0.0.0 FOLLOW_PORT=8099 FOLLOW_DB=/var/lib/follow-server/follow.sqlite FOLLOW_REQUIRE_HTTPS=1
USER follow
EXPOSE 8099
ENTRYPOINT ["/usr/local/bin/follow-server"]
