# PID-only control evidence; no command or output is written to disk.
/bin/sleep 60 &
child=$!
print -r -- "$child" > "$1/child.pid"
print -r -- "$$" > "$1/parent.pid"
trap 'wait "$child"; exit 0' TERM
wait "$child"
