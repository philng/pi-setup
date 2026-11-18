# Test image for Molecule: Debian trixie (what Raspberry Pi OS Lite 64-bit is
# built on) booting systemd, so roles can manage services like on the Pi.
# Built by `make molecule` and in CI as pi-setup-molecule:trixie.
FROM docker.io/library/debian:trixie
ENV container=docker DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv libpam-systemd dbus udev python3 sudo ca-certificates curl procps iproute2 \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 # Units that make no sense in a container.
 && systemctl mask systemd-firstboot.service getty.target console-getty.service
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
