# Ubuntu 22.04 that boots systemd, for tests/install/systemd.sh and tests/debug/systemd.sh.
FROM ubuntu:22.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      systemd systemd-sysv python3 curl unzip openssl ca-certificates passwd >/dev/null && apt-get clean
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
