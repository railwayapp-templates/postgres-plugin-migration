#!/usr/bin/awk -f

BEGIN {
  in_timescaledb_copy = 0;
}

# Consolidate two rules into one using a regex grouping
/^CREATE EXTENSION.*timescaledb|^COMMENT ON EXTENSION.*timescaledb|^SELECT.*timescaledb/ {
  print "-- " $0
  next
}

# Match the start of a COPY block for _timescaledb
/^COPY .*_timescaledb/ {
  in_timescaledb_copy = 1
}

# If we're in a _timescaledb COPY block, comment out everything until the end of the block
in_timescaledb_copy {
  if (/^\\\.$/) {
    in_timescaledb_copy = 0
  }
  print "-- " $0
  next
}

# Print all other lines unmodified
!in_timescaledb_copy {
  print
}
