# Compact PASS/FAIL/SKIP list from a run_qemu test log.
# Handles meson testlog blocks (test:/duration:/result:) and famfs-style
# "## <phase> rc=N" phase markers. Reads the test-results.txt body.
BEGIN { pass=0; fail=0; skip=0 }

/^test:[[:space:]]/     { sub(/^test:[[:space:]]+/,"");     name=$0 }
/^duration:[[:space:]]/ { sub(/^duration:[[:space:]]+/,""); dur=$0 }
/^result:[[:space:]]/ {
    if (name != "") {
        if      ($0 ~ /exit status 0[[:space:]]*$/) { st="PASS"; pass++ }
        else if ($0 ~ /(exit status |code )77/)      { st="SKIP"; skip++ }
        else                                         { st="FAIL"; fail++ }
        printf "%-4s %9s  %s\n", st, dur, name
        name=""; dur=""
    }
}

# famfs-style phase markers, e.g. "## smoke --nofuse rc=0" (ignore "overall")
/^##.*[[:space:]]rc=[0-9]+/ && $0 !~ /overall/ {
    rc=$0; sub(/.*rc=/,"",rc); sub(/[^0-9].*/,"",rc)
    nm=$0; sub(/^##[[:space:]]*/,"",nm); sub(/[[:space:]]+rc=[0-9]+.*/,"",nm); gsub(/-+/,"",nm)
    if (rc=="0") { st="PASS"; pass++ } else { st="FAIL"; fail++ }
    printf "%-4s %9s  %s\n", st, "-", nm
}

END { printf "\n--- summary: %d PASS, %d FAIL, %d SKIP ---\n", pass, fail, skip }
