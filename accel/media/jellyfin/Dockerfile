# Official Jellyfin image with remote VideoToolbox enabled (mdock media bridge).
#
# Jellyfin only builds VideoToolbox pipelines when OperatingSystem.IsMacOS(). Under mdock, ffmpeg runs
# on the Mac (CDI device mdock.dev/media=ffmpeg), so the VideoToolbox checks in the two encoding
# assemblies also accept JELLYFIN_REMOTE_VIDEOTOOLBOX=1, which the CDI device sets. Only those two DLLs
# are rebuilt, from the matching release tag.
#
#   docker build -t mdock/jellyfin:10.11.11 accel/media/jellyfin
ARG JELLYFIN_VERSION=10.11.11
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
ARG JELLYFIN_VERSION
RUN git clone --depth 1 --branch v${JELLYFIN_VERSION} https://github.com/jellyfin/jellyfin /src
WORKDIR /src
RUN remote='(OperatingSystem.IsMacOS() || Environment.GetEnvironmentVariable("JELLYFIN_REMOTE_VIDEOTOOLBOX") == "1")' \
 && for f in MediaBrowser.Controller/MediaEncoding/EncodingHelper.cs MediaBrowser.MediaEncoding/Encoder/MediaEncoder.cs; do \
      sed -i "s/OperatingSystem\.IsMacOS()/$remote/g" "$f"; \
      grep -c JELLYFIN_REMOTE_VIDEOTOOLBOX "$f"; \
    done
RUN dotnet build MediaBrowser.MediaEncoding/MediaBrowser.MediaEncoding.csproj -c Release -o /out -p:TreatWarningsAsErrors=false

FROM jellyfin/jellyfin:${JELLYFIN_VERSION}
COPY --from=build /out/MediaBrowser.Controller.dll /out/MediaBrowser.MediaEncoding.dll /jellyfin/
