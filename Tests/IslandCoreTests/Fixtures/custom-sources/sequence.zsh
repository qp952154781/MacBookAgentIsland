if [[ -f "$1/fail" ]]; then
    print -ru2 -- 'M12_STDERR_PRIVATE_MARKER'
    exit 9
fi
print -r -- 62
