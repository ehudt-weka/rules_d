#!/bin/bash
# Tests exact deps in ldc_wrapper.sh: which candidates and stubs it writes to D_EXACT_DEPS_UNUSED, and when it adds the
# candidates, stubs and source map files, given the files a stub compiler reports through -makedeps and the probe log
# it writes in place of the LD_PRELOAD library.
#
# Usage: exact_deps_test.sh <path to ldc_wrapper.sh>

set -u -o pipefail

wrapper=$(realpath "$1")
cd "${TEST_TMPDIR:-$(mktemp -d)}"

# Copies $FAKE_MAKEDEPS, if set, to the -makedeps= file, as ldc2 would write it; $FAKE_PROBES, if set, to
# $D_EXACT_DEPS_PROBES, if the wrapper set it; prints $FAKE_STDERR, if set, to stderr; exits with $FAKE_EXIT (default 0).
cat > fake_ldc2 <<'EOF'
#!/bin/bash
makedeps=
for arg; do
    case "$arg" in
        -makedeps=*) makedeps=${arg#-makedeps=} ;;
    esac
done
if [ -n "$makedeps" ] && [ -n "${FAKE_MAKEDEPS:-}" ]; then
    cp "$FAKE_MAKEDEPS" "$makedeps"
fi
if [ -n "${D_EXACT_DEPS_PROBES:-}" ] && [ -n "${FAKE_PROBES:-}" ]; then
    cp "$FAKE_PROBES" "$D_EXACT_DEPS_PROBES"
fi
[ -z "${FAKE_STDERR:-}" ] || cat "$FAKE_STDERR" >&2
exit "${FAKE_EXIT:-0}"
EOF
chmod +x fake_ldc2

# The wrapper preloads D_EXACT_DEPS_PRELOAD into the compiler; libc is a library whose preload changes nothing.
preload=$(ldd /bin/sh | awk '/libc\.so/ { print $3 }')

mkdir -p weka/a weka/b lib_source/weka/a strings strings2 stubs/weka/a stubs/weka/b other core out 'out/k=v'
for f in src.d weka/a/x.d weka/a/y.d 'weka/b/sp ace.d' 'weka/b/d$.d' 'weka/b/h#.d' weka/b/z.di weka/b/unread.d \
        other/n.d core/x.d; do
    echo "module m;" > "$f"
done
echo text > strings2/y.txt
# The compiler sees x.d through a source map link.
ln -s ../../../weka/a/x.d lib_source/weka/a/x.d
all_candidates=(weka/a/x.d weka/a/y.d 'weka/b/sp ace.d' 'weka/b/d$.d' 'weka/b/h#.d' weka/b/z.di weka/b/unread.d)
: > source_map
# Every candidate has a stub but z.di (a generated file would have none); y.d has two (two libraries export it); a
# string import has one.
printf '%s\t%s\n' weka/a/x.d stubs/weka/a/x.d weka/a/y.d stubs/weka/a/y.d weka/a/y.d stubs2/weka/a/y.d \
    'weka/b/sp ace.d' 'stubs/weka/b/sp ace.d' 'weka/b/d$.d' 'stubs/weka/b/d$.d' 'weka/b/h#.d' 'stubs/weka/b/h#.d' \
    weka/b/unread.d stubs/weka/b/unread.d strings2/y.txt stubs/strings2/y.txt > stubs_file

# The compile's own source, an import through a link, make's escapes, and no " \" on the last line.
printf '%s\n' 'out/lib.a: \' '  src.d \' '  lib_source/weka/a/x.d \' '  weka/b/sp\ ace.d \' '  weka/b/d$$.d \' \
    '  weka/b/h\#.d \' '  weka/b/z.di' > reads_some
printf '%s\n' 'out/lib.a: \' '  src.d' > reads_src
printf '%s\n' 'out/lib.a: \' '  src.d \' '  weka/missing.d' > reads_missing
# A file that is no dependency's, under a name of its own, and one under a name of the compiler's.
cp reads_some reads_other
printf '%s\n' '  other/n.d' >> reads_other
cp reads_some reads_core
printf '%s\n' '  core/x.d' >> reads_core

# Probe logs. probes_ok: the command-line source is opened (F), each file read is found by a stat (S), by a relative
# path, an absolute one or one through ".."; the lookups that found nothing found the same module elsewhere
# (weka/a/x: no package directory, but a module file), or are not for a module (no identifier path, outside the
# working directory), or are for one of the compiler's own modules.
{
    printf 'F\t%s\n' src.d
    printf 'S\t%s\n' "$PWD/lib_source/weka/a/x.d" 'weka/b/sp ace.d' 'weka/b/d$.d' 'lib_source/../weka/b/h#.d' \
        ./weka/b/z.di other/n.d core/x.d
    printf 'F\t%s\n' "$PWD/lib_source/weka/a/x.d" 'weka/b/sp ace.d' 'weka/b/d$.d' 'weka/b/h#.d' weka/b/z.di
    printf 'D\t%s\n' weka/a weka/b lib_source/weka/a
    printf 'M\t%s\n' weka/a/x.di weka/a/x.d weka/a/x lib_source/weka/a/x.di lib_source/weka/b weka/b/z.d weka/b/z/package.di \
        /etc/ld.so.preload ldc2.conf bazel-out/k8-fastbuild/bin/x core/sys/linux/nope.d lib_source/core/sys/linux/nope.d \
        core/sys/linux/nope.i lib_source/core/sys/linux/nope.c strings/y.txt
    printf 'S\t%s\n' strings2/y.txt
} > probes_ok
cp probes_ok probes_missing_module
printf 'M\t%s\n' weka/c/gone.di weka/c/gone.d lib_source/weka/c/gone.di lib_source/weka/c/gone.d weka/c/gone.i \
    lib_source/weka/c/gone.c >> probes_missing_module
cp probes_ok probes_missing_package
printf 'M\t%s\n' weka/c lib_source/weka/c >> probes_missing_package
cp probes_ok probes_missing_string
printf 'M\t%s\n' strings/s.txt strings2/s.txt >> probes_missing_string
cp probes_ok probes_listing
printf 'L\t%s\n' weka/b >> probes_listing
cp probes_ok probes_unlogged
printf '?\t-\n' >> probes_unlogged
# A module path that is not an identifier path (D allows Unicode identifiers).
cp probes_ok probes_unicode
printf 'M\t%s\n' 'weka/ü/x.d' 'lib_source/weka/ü/x.d' >> probes_unicode
# A directory named q.d is no module q.
cp probes_ok probes_dir_module
printf '%s\t%s\n' D weka/q.d M weka/q.di >> probes_dir_module
grep -v 'z\.di' probes_ok > probes_incomplete
# The files read were opened but not stat'ed: the stat calls are not hooked, so misses would not be logged either.
grep -v '^M' probes_ok | sed 's/^S/F/' > probes_open_only
printf 'M\t%s\n' weka/a/x.di >> probes_open_only
grep -v '^M' probes_ok > probes_no_miss
printf '%s\t%s\n' F src.d M object.di > probes_src
# A string import that finds a directory finds nothing.
cp probes_ok probes_dir_string
printf '%s\t%s\n' M strings/q.txt D strings2/q.txt >> probes_dir_string
# With -J=., a string import is looked up in the working directory too; probes_cwd has no miss that only a string
# import could explain.
grep -v -e 'ldc2\.conf' -e 'bazel-out' probes_ok > probes_cwd
cp probes_cwd probes_cwd_miss
printf 'M\t%s\n' q.txt >> probes_cwd_miss
printf 'own %s\n' other/n.d > resolution_own

failures=0
unused=out/unused
# The compiler's arguments besides the source, -I/-J paths and output.
compiler_args=(--conf=etc/ldc2.conf)

fail() {
    echo "FAIL $1"
    failures=$((failures + 1))
}

# run <makedeps file, or ""> <probe log, or ""> [extra env...]: runs the wrapper; its stderr is out/log.
run() {
    local makedeps=$1 probes=$2
    shift 2
    rm -f "$unused"
    env -i PATH="$PATH" FAKE_MAKEDEPS="$makedeps" FAKE_PROBES="$probes" LDC2_REAL="$PWD/fake_ldc2" \
        D_EXACT_DEPS_CANDIDATES=candidates D_EXACT_DEPS_UNUSED="$unused" "$@" \
        bash "$wrapper" src.d -I=lib_source -J strings -J=strings2 ${compiler_args[@]+"${compiler_args[@]}"} \
        -of=out/lib.a > out/stdout 2> out/log
}

# check <name> <makedeps file, or ""> <probe log, or ""> <expected unused files...>; the candidates are in
# ./candidates. $STUBS, $SOURCE_MAP, $RESOLUTION and $PRELOAD, when set, become the wrapper's environment.
check() {
    local name=$1 makedeps=$2 probes=$3
    shift 3
    if ! run "$makedeps" "$probes" ${STUBS:+D_EXACT_DEPS_STUBS=$STUBS} ${SOURCE_MAP:+LDC2_SOURCE_MAP=$SOURCE_MAP} \
            ${RESOLUTION:+D_EXACT_DEPS_RESOLUTION=$RESOLUTION} ${PRELOAD:+D_EXACT_DEPS_PRELOAD=$PRELOAD}; then
        fail "$name: the wrapper failed:"
        cat out/log
        return
    fi
    if [ $# -gt 0 ]; then printf '%s\n' "$@"; fi > out/expected
    if [ ! -f "$unused" ]; then
        fail "$name: no $unused"
    elif diff out/expected "$unused" > out/diff; then
        echo "ok   $name"
    else
        fail "$name (< expected, > actual):"
        cat out/diff
    fi
}

STUBS= SOURCE_MAP= RESOLUTION= PRELOAD=
printf '%s\n' "${all_candidates[@]}" > candidates
check "no probe log: lists the candidates not read, keeps the candidates file" reads_some "" weka/a/y.d weka/b/unread.d
check "a read path that does not resolve keeps every input" reads_missing ""
check "no makedeps file keeps every input" "" ""
check "makedeps lists only the source: every candidate is unused" reads_src "" "${all_candidates[@]}"

PRELOAD=$preload
check "lookups found elsewhere, or not for a module: the candidates file leaves the key" reads_some probes_ok \
    weka/a/y.d weka/b/unread.d candidates
unused='out/k=v/unused'
check "an output path with '='" reads_some probes_ok weka/a/y.d weka/b/unread.d candidates
unused=out/unused
check "a log made without the library (no LD_PRELOAD) keeps the candidates file" reads_some ""  weka/a/y.d weka/b/unread.d
check "a log that misses a file read keeps the candidates file" reads_some probes_incomplete weka/a/y.d weka/b/unread.d
check "a log with only the source" reads_src probes_src "${all_candidates[@]}" candidates
check "a log whose files read were opened but not stat'ed keeps the candidates file" reads_some probes_open_only \
    weka/a/y.d weka/b/unread.d
check "a log with no failed lookup keeps the candidates file" reads_some probes_no_miss weka/a/y.d weka/b/unread.d
check "a lookup the library could not log keeps the candidates file" reads_some probes_unlogged \
    weka/a/y.d weka/b/unread.d
check "a missing module path that is not an identifier path keeps the candidates file" reads_some probes_unicode \
    weka/a/y.d weka/b/unread.d
check "a directory named like a module file does not explain the module" reads_some probes_dir_module \
    weka/a/y.d weka/b/unread.d
check "a file read that is no dependency's keeps the candidates file" reads_other probes_ok weka/a/y.d weka/b/unread.d
check "a file read that is no dependency's, under a compiler module name" reads_core probes_ok \
    weka/a/y.d weka/b/unread.d candidates
RESOLUTION=resolution_own
check "a file read that is one of the target's own (an \"own\" line)" reads_other probes_ok \
    weka/a/y.d weka/b/unread.d candidates
RESOLUTION=
check "a string import that finds a directory under a later -J path keeps the candidates file" reads_some \
    probes_dir_string weka/a/y.d weka/b/unread.d
compiler_args=()
check "no -conf (the compiler reads ./ldc2.conf if there is one) keeps the candidates file" reads_some probes_ok \
    weka/a/y.d weka/b/unread.d
compiler_args=(-conf etc/ldc2.conf -J=.)
check "-conf as two arguments; -J=. with every miss found elsewhere" reads_some probes_cwd \
    weka/a/y.d weka/b/unread.d candidates
check "-J=.: a string import found nowhere in the working directory keeps the candidates file" reads_some \
    probes_cwd_miss weka/a/y.d weka/b/unread.d
compiler_args=(--conf=etc/ldc2.conf)

STUBS=stubs_file SOURCE_MAP=source_map
check "the stubs of the candidates not read are unused; the stubs and source map files leave the key" \
    reads_some probes_ok weka/a/y.d stubs/weka/a/y.d stubs2/weka/a/y.d weka/b/unread.d stubs/weka/b/unread.d \
    candidates stubs_file source_map
check "a module found nowhere keeps the lists" reads_some probes_missing_module \
    weka/a/y.d stubs/weka/a/y.d stubs2/weka/a/y.d weka/b/unread.d stubs/weka/b/unread.d
check "a package directory found nowhere keeps the lists" reads_some probes_missing_package \
    weka/a/y.d stubs/weka/a/y.d stubs2/weka/a/y.d weka/b/unread.d stubs/weka/b/unread.d
check "a string import found nowhere keeps the lists" reads_some probes_missing_string \
    weka/a/y.d stubs/weka/a/y.d stubs2/weka/a/y.d weka/b/unread.d stubs/weka/b/unread.d
check "a directory listed under an import path keeps the lists" reads_some probes_listing \
    weka/a/y.d stubs/weka/a/y.d stubs2/weka/a/y.d weka/b/unread.d stubs/weka/b/unread.d
check "a path that does not resolve keeps every input" reads_missing probes_ok
STUBS= SOURCE_MAP=

printf '%s\n' "${all_candidates[@]}" weka/b/gone.d > candidates
check "a candidate that does not resolve keeps every input" reads_some probes_ok

: > candidates
check "no candidates: the files read are no dependency's, so the candidates file stays" reads_some probes_ok
check "no candidates, makedeps lists only the source" reads_src probes_src candidates
printf '%s\n' "${all_candidates[@]}" > candidates

# A failed compile fails the wrapper and shows its errors.
printf '%s\n' 'src.d(2): Error: a real error' > real_error
run "" "" D_EXACT_DEPS_PRELOAD="$preload" FAKE_STDERR=real_error FAKE_EXIT=3
rc=$?
if [ "$rc" != 0 ] && grep -q 'a real error' out/log; then
    echo "ok   a failed compile fails and shows its errors"
else
    fail "a failed compile fails and shows its errors (exit $rc):"
    cat out/log
fi

# The reason a compile keeps the lists, with D_EXACT_DEPS_STATS.
run reads_some probes_missing_module D_EXACT_DEPS_PRELOAD="$preload" D_EXACT_DEPS_STATS=1
if grep -q 'lists=found no file for .*weka/c/gone' out/log; then
    echo "ok   D_EXACT_DEPS_STATS says why the lists stay"
else
    fail "D_EXACT_DEPS_STATS says why the lists stay:"
    cat out/log
fi

exit $((failures > 0))
