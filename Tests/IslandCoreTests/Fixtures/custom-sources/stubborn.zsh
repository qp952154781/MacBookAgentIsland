trap '' TERM
print -r -- "$$" > "$1/parent.pid"
/bin/sleep 60 &
wait
