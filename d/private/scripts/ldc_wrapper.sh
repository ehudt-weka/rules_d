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
#   D_EXACT_DEPS_UNUSED - With D_EXACT_DEPS_CANDIDATES: where to write the candidates the compile did not
#                     read, for bazel's unused_inputs_list

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

# Prints the candidates whose real path is not that of a file the compile read. A compile reaches an
# import through a source map link or a sandbox link, so paths are compared after resolving links. Prints
# nothing when a path does not resolve, so that every input stays in the key.
function exact_deps_unused() {
    local deps="$D_EXACT_DEPS_UNUSED.makedeps" read="$D_EXACT_DEPS_UNUSED.read" real="$D_EXACT_DEPS_UNUSED.real"
    # -makedeps writes "<output>: \", then one "  <path> \" line per file read, with make's escapes
    # ($$, \#, \ , \:).
    if ! tail -n +2 "$deps" \
            | sed -e 's/^[[:space:]]*//' -e 's/ \\$//' -e 's/\$\$/$/g' -e 's/\\\([ #:]\)/\1/g' -e '/^$/d' \
            | xargs -r -d '\n' realpath -e -- > "$read" \
        || ! xargs -r -d '\n' realpath -e -- < "$D_EXACT_DEPS_CANDIDATES" > "$real"; then
        echo "exact deps: a path does not resolve; keeping every input" >&2
        return 0
    fi
    # The read list is loaded in BEGIN, not given as a file operand: as an operand, an empty list is hard to
    # tell from the candidates, and awk takes a path with '=' for a variable assignment.
    paste "$D_EXACT_DEPS_CANDIDATES" "$real" | EXACT_DEPS_READ="$read" awk -F '\t' '
        BEGIN { while ((r = (getline line < ENVIRON["EXACT_DEPS_READ"])) > 0) read[line] = 1; if (r < 0) exit 1 }
        !($2 in read) { print $1 }'
}

EXACT_DEPS_ARGS=()
if [ -n "$D_EXACT_DEPS_UNUSED" ]; then
    EXACT_DEPS_ARGS=(-makedeps="$D_EXACT_DEPS_UNUSED.makedeps")
fi

# Compile with real ldc2
"$LDC2_REAL" $DEBUG_PREFIX_MAP "$@" "${EXACT_DEPS_ARGS[@]}" > >(tee stdout.log) 2> >(tee stderr.log >&2)

if [ -n "$D_EXACT_DEPS_UNUSED" ]; then
    exact_deps_unused > "$D_EXACT_DEPS_UNUSED"
    rm -f "$D_EXACT_DEPS_UNUSED".{makedeps,read,real}
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
