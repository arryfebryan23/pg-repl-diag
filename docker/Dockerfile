# PostgreSQL 17 + the OS tooling the diagnostics toolkit relies on.
# The base image ships psql/pg_basebackup/pgbench but NOT the host utilities the
# toolkit reads (python3, ss, iostat/mpstat, ping, ps, iperf3) — add them here so
# every `pg-repl-diag` capability works from inside the container.
FROM postgres:17

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        python3 \
        iproute2 \
        sysstat \
        iperf3 \
        iputils-ping \
        procps \
        util-linux \
 && rm -rf /var/lib/apt/lists/*
