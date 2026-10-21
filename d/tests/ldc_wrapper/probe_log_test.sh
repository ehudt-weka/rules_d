#!/bin/bash
# Tests the exact deps LD_PRELOAD library: the lines it logs for lookups that find a file, a directory or nothing,
# for an open and for a directory listing.
#
# Usage: probe_log_test.sh <path to libd_exact_deps_probes.so> <path to probe_caller>

set -u -o pipefail

lib=$(realpath "$1")
caller=$(realpath "$2")
cd "${TEST_TMPDIR:-$(mktemp -d)}"
mkdir -p dir
echo text > present
rm -f log

LD_PRELOAD="$lib" D_EXACT_DEPS_PROBES="$PWD/log" bash -c '
    test -e missing
    test -d dir
    cat present > /dev/null
    cat dir/missing 2> /dev/null
    ls dir > /dev/null
'
LD_PRELOAD="$lib" D_EXACT_DEPS_PROBES="$PWD/log" "$caller"

failures=0
for line in $'M\tmissing' $'D\tdir' $'F\tpresent' $'M\tdir/missing' $'L\tdir' $'S\tpresent' $'M\tlmissing' \
        $'F\tdir' "M	$PWD/dir/atmissing" "F	$PWD/dir/atopen" $'M\tamissing' $'M\tpresent/sub' $'M\tfmissing'; do
    if grep -q -F -x "$line" log; then
        echo "ok   ${line/$'\t'/ }"
    else
        echo "FAIL ${line/$'\t'/ } not logged"
        failures=$((failures + 1))
    fi
done
if [ "$failures" != 0 ]; then
    echo "log:"
    cat log
fi

# Without D_EXACT_DEPS_PROBES, nothing is logged and nothing breaks.
if LD_PRELOAD="$lib" bash -c 'test -e missing; cat present > /dev/null'; then
    echo "ok   no log file without D_EXACT_DEPS_PROBES"
else
    echo "FAIL a command failed without D_EXACT_DEPS_PROBES"
    failures=$((failures + 1))
fi

exit $((failures > 0))
