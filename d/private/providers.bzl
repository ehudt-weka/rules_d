"""Module containing definitions of D providers."""

def _dinfo_init(
        *,
        bc_output = None,
        bc_linking_context = None,
        compilation_output = None,
        compiler_flags = None,
        imports = None,
        interface_srcs = None,
        linker_flags = None,
        linking_context = None,
        source_map = None,
        source_only = False,
        string_imports = None,
        versions = None,
        libs_bc = None,
        libs_non_bc = None,
        ifc_entries = None,
        ifc_digests = None,
        ifc_names = None):
    """Initializes the DInfo provider."""
    return {
        "ifc_entries": ifc_entries or depset(),
        "ifc_digests": ifc_digests or depset(),
        "ifc_names": ifc_names or depset(),
        "bc_output": bc_output,
        "bc_linking_context": bc_linking_context,
        "compilation_output": compilation_output,
        "compiler_flags": compiler_flags or depset(),
        "imports": imports or depset(),
        "interface_srcs": interface_srcs or depset(),
        "linker_flags": linker_flags or depset(),
        "linking_context": linking_context or depset(),
        "source_map": source_map or {},
        "source_only": source_only,
        "string_imports": string_imports or depset(),
        "versions": versions or depset(),
        "libs_bc": libs_bc or depset(),
        "libs_non_bc": libs_non_bc or depset(),
    }

DInfo, _new_dinfo = provider(
    doc = "Provider containing D compilation information",
    fields = {
        "bc_output": "The bitcode output of the compilation action.",
        "bc_linking_context": "A rules_cc LinkingContext for bitcode libraries.",
        "compilation_output": "The output of the compilation action.",
        "compiler_flags": "List of compiler flags.",
        "imports": "A depset of import paths.",
        "interface_srcs": "A depset of interface source files, transitive sources included.",
        "linker_flags": "List of linker flags, passed directly to the linker.",
        "linking_context": "A rules_cc LinkingContext (essentially a depset of needed libraries, including transitive ones).",
        "source_map": "A dictionary mapping source files to their expected locations.",
        "source_only": "If true, the source files are compiled, but no library is produced.",
        "string_imports": "A depset of string import paths.",
        "versions": "A depset of version identifiers.",
        "libs_bc": "A depset of bitcode library files.",
        "libs_non_bc": "A depset of non-bitcode library files.",
        "ifc_entries": "Body-use cutoff: a depset of struct(input, seen, digest) per D interface source in interface_srcs, with the exec paths of the source and of its digest file, and the path the compiler sees it at.",
        "ifc_digests": "Body-use cutoff: a depset of the digest files of ifc_entries.",
        "ifc_names": "Body-use cutoff: a depset of names files, one per library, listing the line-capturing names its interface sources declare.",
    },
    init = _dinfo_init,
)

IfcDigestInfo = provider(
    doc = "The body-use cutoff's tool (see d/private/tools/ifc_digest/ifc_digest.d).",
    fields = {
        "tool": "FilesToRunProvider of ifc_digest, or None when the cutoff is off.",
        "names": "A depset of names files for the toolchain's own D sources (druntime, phobos).",
        "body_use": "Whether the compiler reports body use with -body-use= (a patched LDC) instead of a time trace.",
    },
)
