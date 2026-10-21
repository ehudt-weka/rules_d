#!/bin/bash
# Drop-in replacement wrapper for ldc2
# Optionally compiles to bitcode archive and unpacks it to a directory
#
# Environment variables:
#   LDC2_REAL       - Path to the real ldc2 compiler (required)
#   BC_UNPACK_DIR   - Directory to unpack bitcode objects (optional)
#                     If not set, just compiles normally without unpacking
#   LDC_SKIP_UNPACK - If set, skip unpacking even if BC_UNPACK_DIR is set
#                     Used in single-action mode where llc_archive_compiler handles unpacking
#   LDC2_SOURCE_MAP - Path to the source map file (optional)
#   AR_CMD          - ar command to use (default: "ar")
#   D_TARGET        - Target we are currently compiling (used for import hints)
#   D_EXACT_DEPS_CANDIDATES - Exact deps (optional): the dependency files (D sources, string-import files) the
#                     compile may read, one exec path per line
#   D_EXACT_DEPS_STUBS - With D_EXACT_DEPS_CANDIDATES (optional): "<file>\t<stub>" lines, the empty stub
#                     that goes with each source file among the dependencies' files
#   D_EXACT_DEPS_RESOLUTION - With D_EXACT_DEPS_CANDIDATES (optional): the resolution file (compile.bzl); its
#                     "own <path>" lines are the target's files that are not on the command line
#   D_EXACT_DEPS_UNUSED - With D_EXACT_DEPS_CANDIDATES: where to write the candidates the compile did not
#                     read and their stubs, for bazel's unused_inputs_list; also the candidates, stubs and
#                     source map files when no file added to a dependency could change what the compile reads
#   D_EXACT_DEPS_PRELOAD - With D_EXACT_DEPS_UNUSED (optional): the LD_PRELOAD library that logs the paths the
#                     compiler looks up; without it, or without a complete log, the lists stay in the key
#   D_EXACT_DEPS_STATS - With D_EXACT_DEPS_UNUSED (optional): print why a compile keeps the lists

set -e -o pipefail

# Check required environment variables
if [ -z "$LDC2_REAL" ]; then
    echo "Error: LDC2_REAL environment variable not set" >&2
    exit 1
fi

# TODO: this is horrible, should we make C++ or Go wrapper instead?
if [ -n "$LDC2_SOURCE_MAP" ]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        target="${line%% *}"
        source="${line#* *}"
        mkdir -p "$(dirname "$source")"
        ln -srf "$PWD/$target" "$source"
    done < "$LDC2_SOURCE_MAP"
fi

DEBUG_PREFIX_MAP=""
if [ -n "$LDC2_DEBUG_REPO_ROOT_OVERRIDE" ]; then
    # this is not enough when running bazel locally, since apparently
    # D toolchain files are _not_ under the sandbox root (current dir)
    # but are under the workspace root (root of the repo).
    # Still, it seems to be working fine with the remote execution.
    # TODO: find a better solution.
    DEBUG_PREFIX_MAP="-fdebug-prefix-map=$PWD=$LDC2_DEBUG_REPO_ROOT_OVERRIDE"
fi

function d_deps_hints() {
    # Extract the missing dependencies from the error message
    # We need to remove the ANSI escape codes
    # TODO: this is horrible, yet another reason to make C++ or Go wrapper instead.
    lines=$(cat stderr.log | sed -r "s/[[:cntrl:]]\[[0-9]{1,3}m//g" | egrep "^[^(]+\([0-9]+\):.*Expected '[^']+' or '[^']+/package.d' in one of the following import paths:")
    OLD_IFS="$IFS"
    IFS=$'\n'
    for line in $lines; do
        from="${line%%(*}"
        # Now extract the path after the "Expected '..."
        to=${line#*Expected \'}
        to=${to%%\'*}
        echo "d_deps_hint: target=$D_TARGET src=$from import=$to"
    done
    IFS=$OLD_IFS
}

trap d_deps_hints ERR

# Prints the candidates whose real path is not that of a file the compile read, and their stubs. A compile
# reaches an import through a source map link or a sandbox link, so paths are compared after resolving links.
# Prints nothing when a path does not resolve, so that every input stays in the key.
function exact_deps_unused() {
    local deps="$D_EXACT_DEPS_UNUSED.deps" read="$D_EXACT_DEPS_UNUSED.read" real="$D_EXACT_DEPS_UNUSED.real"
    # -makedeps writes "<output>: \", then one "  <path> \" line per file read, with make's escapes
    # ($$, \#, \ , \:).
    if ! tail -n +2 "$D_EXACT_DEPS_UNUSED.makedeps" \
            | sed -e 's/^[[:space:]]*//' -e 's/ \\$//' -e 's/\$\$/$/g' -e 's/\\\([ #:]\)/\1/g' -e '/^$/d' > "$deps" \
        || ! xargs -r -d '\n' realpath -e -- < "$deps" > "$read" \
        || ! xargs -r -d '\n' realpath -e -- < "$D_EXACT_DEPS_CANDIDATES" > "$real"; then
        echo "exact deps: a path does not resolve; keeping every input" >&2
        EXACT_DEPS_KEEP_LISTS=1
        return 0
    fi
    # The lists are loaded in BEGIN, not given as file operands: as an operand, an empty list is hard to tell
    # from the candidates, and awk takes a path with '=' for a variable assignment.
    paste "$D_EXACT_DEPS_CANDIDATES" "$real" | EXACT_DEPS_READ="$read" EXACT_DEPS_STUBS="$D_EXACT_DEPS_STUBS" awk -F '\t' '
        BEGIN {
            while ((r = (getline line < ENVIRON["EXACT_DEPS_READ"])) > 0) read[line] = 1
            if (r < 0) exit 1
            if (ENVIRON["EXACT_DEPS_STUBS"] != "") {
                while ((r = (getline line < ENVIRON["EXACT_DEPS_STUBS"])) > 0) {
                    t = index(line, "\t")
                    stubs[substr(line, 1, t - 1)] = stubs[substr(line, 1, t - 1)] "\n" substr(line, t + 1)
                }
                if (r < 0) exit 1
            }
        }
        !($2 in read) { print $1; if ($1 in stubs) print substr(stubs[$1], 2) }'
}

# Succeeds when the probe log shows that no file added to a dependency could change what the compile read: every
# lookup that found no file is one that found a file elsewhere (another extension or import path; a second file
# for the same name changes the resolution file, which stays in the key), or one under a name of the compiler's own
# modules (also in the resolution file). A lookup that found nothing at all, as in a speculative compile
# (__traits(compiles), is(typeof)) importing a missing module, fails it: after the D search the compiler tries
# <module>.i and <module>.c in the working directory and every import path, whatever directories it knows to be
# missing, so such a lookup always leaves those misses.
# It also fails when the log cannot be trusted or covered: a file read (other than a command-line source) with no
# stat line (the stat calls are not hooked), no miss at all, a lookup the library could not log, a directory listing
# under an import path, or a file read that is neither a dependency file nor one of the target's own files under a
# module name that is not the compiler's (the resolution file does not list it). And when no -conf is given: the
# compiler then reads an ldc2.conf from the working directory, which a dependency could add.
function exact_deps_probes_explained() {
    local probes="$D_EXACT_DEPS_UNUSED.probes" known="$D_EXACT_DEPS_UNUSED.known" iroots=() jroots=() srcs=() next= conf=
    [ -s "$probes" ] || { EXACT_DEPS_WHY="no probe log"; return 1; }
    for arg in "$@"; do
        if [ -n "$next" ]; then
            case "$next" in
                I) iroots+=("$arg") ;;
                J) jroots+=("$arg") ;;
            esac
            next=
            continue
        fi
        case "$arg" in
            -conf=* | --conf=*) conf=1 ;;
            -conf | --conf) conf=1; next=C ;;
            -I=*) iroots+=("${arg#-I=}") ;;
            -J=*) jroots+=("${arg#-J=}") ;;
            -I) next=I ;;
            -J) next=J ;;
            -I*) iroots+=("${arg#-I}") ;;
            -J*) jroots+=("${arg#-J}") ;;
            @*) EXACT_DEPS_WHY="a response file"; return 1 ;;
            -*) ;;
            *.d | *.di) srcs+=("$arg") ;;
        esac
    done
    [ -n "$conf" ] || { EXACT_DEPS_WHY="no -conf"; return 1; }
    # The real paths of the dependency files, the command-line sources and the target's other files.
    if ! { cat "$D_EXACT_DEPS_UNUSED.real"
            { printf '%s\n' "${srcs[@]}"; [ -z "$D_EXACT_DEPS_RESOLUTION" ] || sed -n 's/^own //p' "$D_EXACT_DEPS_RESOLUTION"; } \
                | sed '/^$/d' | xargs -r -d '\n' realpath -e --; } > "$known"; then
        EXACT_DEPS_WHY="a source of the target does not resolve"
        return 1
    fi
    EXACT_DEPS_WHY=$(
        EXACT_DEPS_PWD_L="$PWD" EXACT_DEPS_PWD_P="$(pwd -P)" EXACT_DEPS_DEPS="$D_EXACT_DEPS_UNUSED.deps" \
        EXACT_DEPS_READ="$D_EXACT_DEPS_UNUSED.read" EXACT_DEPS_KNOWN="$known" \
        EXACT_DEPS_I="$(printf '%s\n' "${iroots[@]}")" EXACT_DEPS_J="$(printf '%s\n' "${jroots[@]}")" \
        EXACT_DEPS_SRCS="$(printf '%s\n' "${srcs[@]}")" \
        awk '
        # The path relative to the working directory, without "." or ".." components; absolute when outside it.
        function clean(p,    abs, n, part, out, i, k, r) {
            if (substr(p, 1, 1) == "/") {
                if (p == pwdl || p == pwdp) p = ""
                else if (index(p, pwdl "/") == 1) p = substr(p, length(pwdl) + 2)
                else if (index(p, pwdp "/") == 1) p = substr(p, length(pwdp) + 2)
            }
            abs = substr(p, 1, 1) == "/"
            n = split(p, part, "/")
            k = 0
            for (i = 1; i <= n; i++) {
                if (part[i] == "" || part[i] == ".") continue
                if (part[i] == ".." && k > 0 && out[k] != "..") { k--; continue }
                out[++k] = part[i]
            }
            r = ""
            for (i = 1; i <= k; i++) r = r (i > 1 ? "/" : "") out[i]
            return abs ? "/" r : r
        }
        # The names a lookup of path p was for, in keys[]: "m:a/b" for module a.b (any extension the compiler
        # tries, a/b/package.d too), "d:a/b" for package directory a/b, "j:<name>" for a string import. kind is the
        # kind of the log line: a directory found (D) has no module or string import name, a file found (S, F) no
        # directory name.
        # Returns the number of module names, or -1 for a path without a module extension or outside the working
        # directory; 0 means a module path that is not an identifier path.
        function names(p, kind, keys,    i, rel, stem, nm) {
            split("", keys)
            nm = 0
            if (p == "" || substr(p, 1, 1) == "/") return -1
            for (i = 0; i <= ni; i++) {
                if (iroot[i] == "") rel = p
                else if (index(p, iroot[i] "/") == 1) rel = substr(p, length(iroot[i]) + 2)
                else continue
                if (match(rel, /\.(di|d|i|c)$/)) {
                    stem = substr(rel, 1, RSTART - 1)
                    sub(/\/package$/, "", stem)
                    if (stem ~ idpath && kind != "D") { keys["m:" stem] = 1; nm++ }
                } else if (rel ~ idpath && kind != "S" && kind != "F") keys["d:" rel] = 1
            }
            for (i = 1; i <= nj && kind != "D"; i++)
                if (jroot[i] == "") keys["j:" p] = 1
                else if (index(p, jroot[i] "/") == 1) keys["j:" substr(p, length(jroot[i]) + 2)] = 1
            return p ~ /\.(di|d|i|c)$/ ? nm : -1
        }
        function reserved(key,    top) {
            if (key !~ /^[md]:/) return 0
            top = substr(key, 3)
            sub(/\/.*/, "", top)
            return top in compiler
        }
        function fail(why) {
            if (!why_first) why_first = why
        }
        BEGIN {
            pwdl = ENVIRON["EXACT_DEPS_PWD_L"]; pwdp = ENVIRON["EXACT_DEPS_PWD_P"]
            idpath = "^[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*)*$"
            # The top-level names of the import path of the compiler; compile.bzl has the same list.
            split("core std etc ldc object __builtins __importc_builtins importc", top, " ")
            for (i in top) compiler[top[i]] = 1
            iroot[0] = ""
            ni = 0
            n = split(ENVIRON["EXACT_DEPS_I"], roots, "\n")
            for (i = 1; i <= n; i++) if ((r = clean(roots[i])) != "" && substr(r, 1, 1) != "/") iroot[++ni] = r
            nj = 0
            n = split(ENVIRON["EXACT_DEPS_J"], roots, "\n")
            for (i = 1; i <= n; i++) if (roots[i] != "") jroot[++nj] = clean(roots[i])
            n = split(ENVIRON["EXACT_DEPS_SRCS"], roots, "\n")
            for (i = 1; i <= n; i++) if (roots[i] != "") cmdline[clean(roots[i])] = 1
            while ((r = (getline line < ENVIRON["EXACT_DEPS_KNOWN"])) > 0) known[line] = 1
            if (r < 0) fail("no list of dependency files")
            # The files read, by the path the compiler used and by real path, line by line.
            nr = 0
            while ((r = (getline line < ENVIRON["EXACT_DEPS_DEPS"])) > 0) readpath[++nr] = clean(line)
            if (r < 0) fail("no makedeps list")
            for (i = 1; i <= nr; i++) if ((getline line < ENVIRON["EXACT_DEPS_READ"]) > 0) readreal[i] = line
        }
        index($0, "\t") == 2 {
            kind = substr($0, 1, 1)
            p = clean(substr($0, 3))
            if (kind == "?") { fail("a lookup the library could not log"); next }
            if (kind == "M" || kind == "E") { failed[p] = 1; nfailed++; next }
            if (kind == "S" || kind == "D") statted[p] = 1
            if (kind == "S" || kind == "F") opened[p] = 1
            if (kind == "L") listed[p] = 1
            names(p, kind, keys)
            for (k in keys) found[k] = 1
        }
        END {
            for (i = 1; i <= nr; i++) {
                p = readpath[i]
                if ((p in cmdline) ? !(p in opened) : !(p in statted)) fail("the probe log misses " p)
                if (!(readreal[i] in known)) {
                    names(p, "S", keys)
                    for (k in keys) if (k ~ /^m:/ && !reserved(k)) fail("read " p ", not a dependency file")
                }
            }
            if (!nfailed) fail("no failed lookup in the probe log")
            for (p in listed) {
                names(p, "L", keys)
                for (k in keys) fail("listed " p)
            }
            # A package directory that is missing is explained by the module of that name found as a file: after
            # a.d is missing, the compiler checks whether a/ is a package.
            for (p in failed) {
                nm = names(p, "M", keys)
                n = 0
                ok = 0
                for (k in keys) {
                    n++
                    if ((k in found) || reserved(k) || (k ~ /^d:/ && ("m:" substr(k, 3)) in found)) ok = 1
                }
                if ((n && !ok) || nm == 0) unexplained[++nu] = p
            }
            if (nu) {
                r = "found no file for " unexplained[1]
                for (i = 2; i <= nu && i <= 5; i++) r = r ", " unexplained[i]
                fail(r (nu > 5 ? " and " nu - 5 " more" : ""))
            }
            if (why_first) {
                print why_first
                exit 1
            }
        }' "$probes"
    )
}

# Prints the candidates, stubs and source map files: they leave the key unless the compile looked up a file that a
# file added to a dependency could provide (exact_deps_probes_explained).
function exact_deps_lists_unused() {
    if [ -n "$EXACT_DEPS_KEEP_LISTS" ]; then
        return 0
    fi
    if ! exact_deps_probes_explained "$@"; then
        return 0
    fi
    printf '%s\n' "$D_EXACT_DEPS_CANDIDATES"
    if [ -n "$D_EXACT_DEPS_STUBS" ]; then
        printf '%s\n' "$D_EXACT_DEPS_STUBS"
    fi
    if [ -n "$LDC2_SOURCE_MAP" ]; then
        printf '%s\n' "$LDC2_SOURCE_MAP"
    fi
}

EXACT_DEPS_ARGS=()
EXACT_DEPS_ENV=()
EXACT_DEPS_KEEP_LISTS=
if [ -n "$D_EXACT_DEPS_UNUSED" ]; then
    EXACT_DEPS_ARGS=(-makedeps="$D_EXACT_DEPS_UNUSED.makedeps")
    rm -f "$D_EXACT_DEPS_UNUSED.probes"
    if [ -n "$D_EXACT_DEPS_PRELOAD" ]; then
        preload=$D_EXACT_DEPS_PRELOAD
        [[ "$preload" == /* ]] || preload="$PWD/$preload"
        EXACT_DEPS_ENV=(LD_PRELOAD="$preload${LD_PRELOAD:+:$LD_PRELOAD}" D_EXACT_DEPS_PROBES="$PWD/$D_EXACT_DEPS_UNUSED.probes")
    fi
fi

# Compile with real ldc2
env "${EXACT_DEPS_ENV[@]}" "$LDC2_REAL" $DEBUG_PREFIX_MAP "$@" "${EXACT_DEPS_ARGS[@]}" > >(tee stdout.log) 2> >(tee stderr.log >&2)

if [ -n "$D_EXACT_DEPS_UNUSED" ]; then
    exact_deps_unused > "$D_EXACT_DEPS_UNUSED"
    EXACT_DEPS_WHY="a path does not resolve"
    exact_deps_lists_unused "$@" >> "$D_EXACT_DEPS_UNUSED"
    if [ -n "$D_EXACT_DEPS_STATS" ]; then  # --define=D_EXACT_DEPS_STATS=1
        echo "exact deps stats: probes=$(cat "$D_EXACT_DEPS_UNUSED.probes" 2>/dev/null | wc -l)" \
            "unused=$(wc -l < "$D_EXACT_DEPS_UNUSED") lists=${EXACT_DEPS_WHY:-pruned}" >&2
    fi
    rm -f "$D_EXACT_DEPS_UNUSED".{makedeps,deps,read,real,probes,known}
fi

# If LDC_SKIP_UNPACK is set, skip unpacking (for single-action mode)
if [ -n "$LDC_SKIP_UNPACK" ]; then
    exit 0
fi

# If BC_UNPACK_DIR is set, unpack the archive
if [ -n "$BC_UNPACK_DIR" ]; then
    # Default ar command
    AR_CMD="${AR_CMD:-ar}"

    # Find the output file from arguments (-of=...)
    OUTPUT_FILE=""
    for arg in "$@"; do
        if [[ "$arg" == -of=* ]]; then
            OUTPUT_FILE="${arg#-of=}"
            break
        fi
    done

    if [ -z "$OUTPUT_FILE" ]; then
        echo "Error: BC_UNPACK_DIR set but no output file specified (-of=...)" >&2
        exit 1
    fi

    # Convert to absolute path before changing directory
    if [[ "$OUTPUT_FILE" != /* ]]; then
        OUTPUT_FILE="$PWD/$OUTPUT_FILE"
    fi

    # Unpack bitcode archive to output directory
    mkdir -p "$BC_UNPACK_DIR"
    cd "$BC_UNPACK_DIR"
    "$AR_CMD" x "$OUTPUT_FILE"
fi
