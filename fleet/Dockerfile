# ---- Stage 1: fetch the statically linked Fleet server binary ----
FROM alpine:3.20 AS fleet
ARG FLEET_VERSION=4.92.2
RUN apk add --no-cache curl tar \
 && curl -fsSL -o /tmp/fleet.tgz \
      "https://github.com/fleetdm/fleet/releases/download/fleet-v${FLEET_VERSION}/fleet_v${FLEET_VERSION}_linux.tar.gz" \
 && tar -xzf /tmp/fleet.tgz -C /tmp \
 && install -m 0755 "/tmp/fleet_v${FLEET_VERSION}_linux/fleet" /fleet

# ---- Stage 2: Oracle MySQL 8.4 LTS (Fleet does not support MariaDB) ----
FROM mysql:8.4-oracle

# redis, jq, openssl from Oracle Linux 9 BaseOS/AppStream
RUN microdnf install -y redis jq openssl procps-ng \
 && microdnf clean all

COPY --from=fleet /fleet /usr/local/bin/fleet
COPY rootfs/ /
RUN chmod 0755 /usr/local/bin/run.sh \
 && /usr/local/bin/fleet version </dev/null

ENTRYPOINT []
CMD ["/usr/local/bin/run.sh"]
