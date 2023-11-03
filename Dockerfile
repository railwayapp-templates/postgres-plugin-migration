FROM ubuntu:jammy

# Add the PostgreSQL Apt Repository for PostgreSQL packages
RUN apt-get update && \
    apt-get install -y gnupg wget && \
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - && \
    echo "deb http://apt.postgresql.org/pub/repos/apt/ $(grep UBUNTU_CODENAME /etc/os-release | cut -d= -f2)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

# Install postgresql-client-16
RUN apt-get update && \
    apt-get install -y postgresql-client-16 bash ncurses-bin && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ADD . .

CMD ["bash", "migrate.sh"]
