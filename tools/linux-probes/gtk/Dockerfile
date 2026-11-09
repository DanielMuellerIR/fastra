FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends python3-gi gir1.2-gtk-4.0 gir1.2-gtksource-5 gir1.2-webkit-6.0 xvfb xauth dbus-x11 weston && rm -rf /var/lib/apt/lists/*
ENV PYTHONUNBUFFERED=1
