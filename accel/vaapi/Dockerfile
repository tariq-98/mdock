# Builds the guest VA-API driver for linux/arm64 against Debian bookworm's glibc and libva 2.17
# (VA-API 1.17). It runs unchanged on trixie and with newer libva (e.g. jellyfin-ffmpeg's 2.24),
# which looks for __vaDriverInit_1_<n> from its own version down.
FROM debian:bookworm AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc libc6-dev make libva-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Makefile ./
COPY src ./src
RUN make OUT=/out all /out/vtbench

FROM scratch
COPY --from=build /out/ /
