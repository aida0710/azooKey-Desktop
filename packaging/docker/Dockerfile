FROM swift:6.2-noble
ENV DEBIAN_FRONTEND=noninteractive
# Dependencies are installed only inside this disposable Ubuntu image.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl-dev zlib1g-dev libcurl4-openssl-dev \
    python3 python3-gi python3-gi-cairo python3-cairo gir1.2-ibus-1.0 gir1.2-gtk-3.0 gir1.2-secret-1 \
    ibus dbus-x11 xvfb xdotool fonts-noto-cjk gsettings-desktop-schemas \
    && rm -rf /var/lib/apt/lists/*
ARG AZOOKEY_BUILD_COMMIT
ENV AZOOKEY_BUILD_COMMIT=${AZOOKEY_BUILD_COMMIT}
WORKDIR /workspace
COPY . .
CMD ["bash", "Tools/test-linux.sh"]
