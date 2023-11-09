FROM ubuntu:jammy

# Add the PostgreSQL Apt Repository for PostgreSQL packages
RUN apt-get update && \
    apt-get install -y gnupg wget && \
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - && \
    echo "deb http://apt.postgresql.org/pub/repos/apt/ $(grep UBUNTU_CODENAME /etc/os-release | cut -d= -f2)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

# Install postgresql-client-16
RUN apt-get update && \
    apt-get install -y postgresql-client-16 bash make ncurses-bin libdatetime-perl libdbd-pg-perl git && \
    rm -rf /var/lib/apt/lists/*

# Install pg_dumpbinary
RUN git clone https://github.com/lzlabs/pg_dumpbinary.git
RUN cd pg_dumpbinary && \
    perl Makefile.PL && \
    make && \
    make install

WORKDIR /app

ADD . .

CMD ["bash", "migrate.sh"]
