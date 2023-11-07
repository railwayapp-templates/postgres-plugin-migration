#!/usr/bin/awk -f

BEGIN {
  in_timescaledb_copy = 0;
  every_n_lines = 1000000;
}

/^CREATE EXTENSION.*timescaledb|^COMMENT ON EXTENSION.*timescaledb|^SELECT.*timescaledb/ {
  print "-- " $0
  next
}

/^COPY .*_timescaledb/ {
  in_timescaledb_copy = 1
}

in_timescaledb_copy {
  if (/^\\\.$/) {
    in_timescaledb_copy = 0
  }
  print "-- " $0
  next
}

!in_timescaledb_copy {
  print
}

# Progress report
NR % every_n_lines == 0 {
  printf "Processed %d lines of dump file.\n", NR > "/dev/stderr"
}
