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
#   IFC_DIGEST      - Body-use cutoff: path to ifc_digest (optional). With it, the wrapper writes to
#                     IFC_UNUSED_INPUTS the candidates in IFC_CANDIDATES the compile did not depend on.
#   IFC_BODY_USE    - If set, the compiler reports body use with -body-use= instead of a time trace

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

# Whether the compile can inline functions of other modules, which it then analyses with no trace
# event; ifc_digest's pruning assumes it does not.
function cross_module_inlining() {
    for arg in "$@"; do
        case "$arg" in
            -O0|--O0|-enable-inlining=false|--enable-inlining=false|-enable-inlining=0|--enable-inlining=0) ;;
            -enable-cross-module-inlining=false|--enable-cross-module-inlining=false) ;;
            -enable-cross-module-inlining=0|--enable-cross-module-inlining=0) ;;
            -O*|--O*|-inline|-enable-inlining*|--enable-inlining*) return 0 ;;
            -enable-cross-module-inlining*|--enable-cross-module-inlining*) return 0 ;;
        esac
    done
    return 1
}

IFC_ARGS=()
IFC_PRUNE=""
IFC_TRACE=""
IFC_USE=""
if [ -n "$IFC_DIGEST" ]; then
    if cross_module_inlining "$@"; then
        : > "$IFC_UNUSED_INPUTS"
    else
        IFC_PRUNE=1
        IFC_DEPS="$IFC_UNUSED_INPUTS.makedeps"
        # Not -deps: it makes the compiler analyse every imported body.
        if [ -n "$IFC_BODY_USE" ]; then
            IFC_USE="$IFC_UNUSED_INPUTS.bodyuse"
            IFC_ARGS=(-makedeps="$IFC_DEPS" -body-use="$IFC_USE")
        else
            IFC_TRACE="$IFC_UNUSED_INPUTS.trace.json"
            IFC_ARGS=(-makedeps="$IFC_DEPS" --ftime-trace --ftime-trace-granularity=0 --ftime-trace-file=-)
        fi
    fi
fi

# Compile with real ldc2
if [ -n "$IFC_TRACE" ]; then
    # The trace goes to stdout: LDC writes a trace file with a single write(2), which Linux caps at
    # 2 GiB. prune prints whatever else the compiler wrote there.
    "$LDC2_REAL" $DEBUG_PREFIX_MAP "$@" "${IFC_ARGS[@]}" > "$IFC_TRACE" 2> >(tee stderr.log >&2)
else
    "$LDC2_REAL" $DEBUG_PREFIX_MAP "$@" "${IFC_ARGS[@]}" > >(tee stdout.log) 2> >(tee stderr.log >&2)
fi

if [ -n "$IFC_PRUNE" ]; then
    if [ -n "$IFC_USE" ]; then
        IFC_SOURCE=(--body-use="$IFC_USE")
    else
        IFC_SOURCE=(--trace="$IFC_TRACE")
    fi
    "$IFC_DIGEST" prune --candidates="$IFC_CANDIDATES" --makedeps="$IFC_DEPS" "${IFC_SOURCE[@]}" \
        --out="$IFC_UNUSED_INPUTS"
    rm -f "$IFC_DEPS" "$IFC_TRACE" "$IFC_USE"
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
