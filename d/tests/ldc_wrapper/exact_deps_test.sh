#!/bin/bash
# Tests exact deps in ldc_wrapper.sh: which candidates it writes to D_EXACT_DEPS_UNUSED, given the files a
# stub compiler reports through -makedeps.
#
# Usage: exact_deps_test.sh <path to ldc_wrapper.sh>

set -u -o pipefail

wrapper=$(realpath "$1")
cd "${TEST_TMPDIR:-$(mktemp -d)}"

# Copies $FAKE_MAKEDEPS, if set, to the -makedeps= file, as ldc2 would write it.
cat > fake_ldc2 <<'EOF'
#!/bin/bash
for arg; do
    case "$arg" in
        -makedeps=*) [ -z "$FAKE_MAKEDEPS" ] || cp "$FAKE_MAKEDEPS" "${arg#-makedeps=}" ;;
    esac
done
EOF
chmod +x fake_ldc2

mkdir -p weka/a weka/b lib_source/weka/a out 'out/k=v'
for f in src.d weka/a/x.d weka/a/y.d 'weka/b/sp ace.d' 'weka/b/d$.d' 'weka/b/h#.d' weka/b/z.di weka/b/unread.d; do
    echo "module m;" > "$f"
done
# The compiler sees x.d through a source map link.
ln -s ../../../weka/a/x.d lib_source/weka/a/x.d
all_candidates=(weka/a/x.d weka/a/y.d 'weka/b/sp ace.d' 'weka/b/d$.d' 'weka/b/h#.d' weka/b/z.di weka/b/unread.d)

# The compile's own source, an import through a link, make's escapes, and no " \" on the last line.
printf '%s\n' 'out/lib.a: \' '  src.d \' '  lib_source/weka/a/x.d \' '  weka/b/sp\ ace.d \' '  weka/b/d$$.d \' \
    '  weka/b/h\#.d \' '  weka/b/z.di' > reads_some
printf '%s\n' 'out/lib.a:' > reads_none
printf '%s\n' 'out/lib.a: \' '  src.d \' '  weka/missing.d' > reads_missing

failures=0
unused=out/unused

# check <name> <makedeps file, or "" for none> <expected unused files...>; the candidates are in ./candidates.
check() {
    local name=$1 makedeps=$2
    shift 2
    rm -f "$unused"
    if ! env -i PATH="$PATH" FAKE_MAKEDEPS="$makedeps" LDC2_REAL="$PWD/fake_ldc2" \
            D_EXACT_DEPS_CANDIDATES=candidates D_EXACT_DEPS_UNUSED="$unused" \
            bash "$wrapper" src.d -of=out/lib.a > out/log 2>&1; then
        echo "FAIL $name: the wrapper failed:"
        cat out/log
        failures=$((failures + 1))
        return
    fi
    if [ $# -gt 0 ]; then printf '%s\n' "$@"; fi > out/expected
    if [ ! -f "$unused" ]; then
        echo "FAIL $name: no $unused"
        failures=$((failures + 1))
    elif diff out/expected "$unused" > out/diff; then
        echo "ok   $name"
    else
        echo "FAIL $name (< expected, > actual):"
        cat out/diff
        failures=$((failures + 1))
    fi
}

printf '%s\n' "${all_candidates[@]}" > candidates
check "lists the candidates not read" reads_some weka/a/y.d weka/b/unread.d
check "makedeps lists no file: every candidate is unused" reads_none "${all_candidates[@]}"
check "a read path that does not resolve keeps every input" reads_missing
check "no makedeps file keeps every input" ""
unused='out/k=v/unused'
check "an output path with '=' in it" reads_some weka/a/y.d weka/b/unread.d
unused=out/unused

printf '%s\n' "${all_candidates[@]}" weka/b/gone.d > candidates
check "a candidate that does not resolve keeps every input" reads_some

: > candidates
check "no candidates" reads_some
check "no candidates, makedeps lists no file" reads_none

exit $((failures > 0))
