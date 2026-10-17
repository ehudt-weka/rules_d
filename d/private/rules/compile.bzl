"""Compilation action for D rules."""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_cc//cc:defs.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//d:providers.bzl", "DSourceInfo", "DDepsInfo")
load("//d/private:providers.bzl", "DInfo")
load("//d/private/rules:bitcode.bzl", "compile_bitcode_single_action", "compile_bitcode_to_native", "repack_native_objects")
load("//d/private/rules:hdrgen.bzl", "generate_headers_action")
load("//d/private/rules:utils.bzl", "compute_object_file_names", "compute_project_root", "object_file_name", "resolve_tristate_flag", "static_library_name", "validate_sources_under_project_root")
load("//d/private/rules:source_map.bzl", "write_source_map", "filter_source_map", "merge_source_maps")

D_FILE_EXTENSIONS = [".d", ".di"]

common_attrs = {
    "srcs": attr.label_list(
        doc = "List of D '.d' or '.di' source files.",
        default = [],
        allow_files = D_FILE_EXTENSIONS,
        allow_empty = True,
    ),
    "preprocessed_srcs": attr.label(
        doc = "The preprocessed source files.",
        providers = [DSourceInfo],
    ),
    "deps": attr.label_list(doc = "List of dependencies.", default = [], providers = [[CcInfo], [DInfo], [DDepsInfo]]),
    "dopts": attr.string_list(doc = "Compiler flags.", default = []),
    "d_features": attr.string_list(doc = "D toolchain features to enable for this target (not propagated transitively).", default = []),
    "imports": attr.string_list(doc = "List of import paths.", default = []),
    "linkopts": attr.string_list(doc = "Linker flags passed via -L flags.", default = []),
    "string_imports": attr.string_list(doc = "List of string import paths.", default = []),
    "string_srcs": attr.label_list(doc = "List of string import source files.", allow_files = True, default = []),
    "versions": attr.string_list(doc = "List of version identifiers.", default = []),
    "compile_via_bc": attr.string(
        default = "auto",
        values = ["auto", "on", "off"],
        doc = "Enables staged compilation via bitcode.",
    ),
    "project_root": attr.string(
        default = "",
        doc = """Specifies where D module names are computed from.
            - "" (default): Repository root. Module names are relative to repo root (recommended).
            - ".": Current package directory. Module names are relative to the BUILD file location.
            - "./subdir": Subdirectory within the package.
            - "../..": Parent directories relative to the package.
            - "some/path": Absolute path from repository root.
        """,
    ),
    "_ldc_wrapper_script": attr.label(
        default = "//d/private/scripts:ldc_wrapper.sh",
        allow_single_file = True,
        doc = "LDC wrapper script for unified compilation",
    ),
    "_llc_archive_compiler": attr.label(
        default = "//d/private/scripts:compile_bitcode.sh",
        allow_single_file = True,
        doc = "Bitcode compilation script for single-action bitcode compilation",
    ),
    "_exact_deps": attr.label(
        default = "//:exact_deps",
        providers = [BuildSettingInfo],
        doc = "Whether a compile's action key holds only the imported D sources it read",
    ),
    "_linux_constraint": attr.label(default = "@platforms//os:linux", doc = "Linux platform constraint"),
    "_macos_constraint": attr.label(default = "@platforms//os:macos", doc = "macOS platform constraint"),
    "_windows_constraint": attr.label(default = "@platforms//os:windows", doc = "Windows platform constraint"),
}

runnable_attrs = dicts.add(
    common_attrs,
    {
        "env": attr.string_dict(doc = "Environment variables for the binary at runtime. Subject of location and make variable expansion."),
        "data": attr.label_list(allow_files = True, doc = "List of files to be made available at runtime."),
        "dynamic_symbols": attr.label(allow_files = True, doc = "List of dynamic symbols to be passed to the linker."),
        "fat_lto": attr.string(default = "auto", values = ["auto", "on", "off"], doc = "Whether to use fat LTO."),
        "linker_script": attr.label(allow_single_file = True, doc = "Linker script to be used for the binary."),
        "link_with_d": attr.string(default = "auto", values = ["auto", "on", "off"], doc = "Whether to use the D compiler for linking."),
        "additional_linker_inputs": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Additional inputs made visible to the link action (matches cc_library.additional_linker_inputs).",
        ),
        "link_output_dirs": attr.string_list(
            default = [],
            doc = "Names of additional TreeArtifact directory outputs the link action will produce. The link action declares them, surfaces them via DefaultInfo.files, and (cc_common.link path only) passes them to cc_common.link's additional_outputs so the linker — or a wrapper invoked through it — can populate them.",
        ),
        "_cc_toolchain": attr.label(
            default = "@rules_cc//cc:current_cc_toolchain",
            doc = "Default CC toolchain, used for linking. Remove after https://github.com/bazelbuild/bazel/issues/7260 is flipped (and support for old Bazel version is not needed)",
        ),
        "_extract_archive_script": attr.label(
            default = "//d/private/scripts:extract_archive.sh",
            allow_single_file = True,
            doc = "Script to extract archive to a directory",
        ),
    },
)

library_attrs = dicts.add(
    common_attrs,
    {
        "source_only": attr.bool(doc = "If true, the source files are compiled, but not library is produced."),
        "single_object": attr.string(
            default = "auto",
            values = ["auto", "on", "off"],
            doc = """Controls library compilation mode:
                - "auto": Use toolchain default (from toolchain config)
                - "on": Single object mode (archive with one object file)
                - "off": Multi-object mode (archive with multiple object files)
            """,
        ),
        "hdrs": attr.label_list(
            allow_files = D_FILE_EXTENSIONS,
            doc = "D header/interface files (.di) for public API.",
            default = [],
        ),
        "exports": attr.label_list(
            allow_files = D_FILE_EXTENSIONS,
            doc = "D source files to export as public API.",
            default = [],
        ),
        "implementation_deps": attr.label_list(
            doc = "Private dependencies not propagated to consumers.",
            providers = [[CcInfo], [DInfo], [DDepsInfo]],
            default = [],
        ),
        "link_only_deps": attr.label_list(
            doc = """Link-only dependencies: their object code is propagated
                transitively to the final binary, but their interface is NOT
                added to this target's compile inputs and NOT propagated to
                consumers. Use for object-code transit edges where the
                interface is already supplied through `deps` (e.g. fine-grained
                per-file -exports leaves), so the compile rebuild cone stays
                narrow while linking still works via transit.""",
            providers = [[CcInfo], [DInfo], [DDepsInfo]],
            default = [],
        ),
        "qualified_object_file_names": attr.string(
            default = "auto",
            values = ["auto", "on", "off"],
            doc = """Controls object file naming in archives:
                - "auto": Use toolchain default
                - "on": Use qualified names (package.path.basename.o)
                - "off": Use basename only (basename.o)
            """,
        ),
        "generate_headers": attr.string(
            default = "auto",
            values = ["auto", "on", "off"],
            doc = """Controls whether to generate headers for exported sources:
                - "auto": Use toolchain default
                - "on": Always generate headers (requires toolchain.hdrgen_flags)
                - "off": Never generate headers
            """,
        ),
        "exports_no_hdrs": attr.label_list(
            allow_files = D_FILE_EXTENSIONS,
            doc = """Exported sources that should NOT go through header generation.
                These will be exported directly as sources.
                Useful for sources that must be available in full (e.g., for CTFE).
            """,
            default = [],
        ),
        "alwayslink": attr.bool(
            default = False,
            doc = "If true, the library is always linked.",
        ),
    },
)

TARGET_TYPE = struct(
    BINARY = "binary",
    LIBRARY = "library",
    TEST = "test",
)

def _compilation_config_from_ctx(ctx, target_type, srcs):
    toolchain = ctx.toolchains["//d:toolchain_type"].d_toolchain_info
    compile_via_bc = resolve_tristate_flag(ctx.attr.compile_via_bc, toolchain.compile_via_bc)
    if compile_via_bc:
        if not toolchain.output_bc_flags:
            fail("Bitcode compilation requested but toolchain.output_bc_flags not set")
    single_object = hasattr(ctx.attr, "single_object") and resolve_tristate_flag(ctx.attr.single_object, toolchain.single_object)
    if single_object:
        # Verify compiler supports single object mode
        if not toolchain.single_obj_flag:
            fail("Single object mode requested but not supported by compiler. " +
                    "Use LDC toolchain or set single_object='off'.")
    use_single_action = (target_type != TARGET_TYPE.LIBRARY) or single_object or len(srcs) == 1
    qualified_object_file_names = hasattr(ctx.attr, "qualified_object_file_names") and resolve_tristate_flag(ctx.attr.qualified_object_file_names, toolchain.qualified_object_file_names)
    generate_headers = hasattr(ctx.attr, "generate_headers") and resolve_tristate_flag(ctx.attr.generate_headers, toolchain.generate_headers)
    if generate_headers and not toolchain.hdrgen_flags:
        fail("generate_headers='on' but toolchain.hdrgen_flags is empty. " +
             "Update your D toolchain configuration to support header generation.")
    return struct(
        compile_via_bc = compile_via_bc,
        qualified_object_file_names = qualified_object_file_names,
        single_object = single_object,
        use_single_action = use_single_action,
        project_root = compute_project_root(ctx, ctx.attr.project_root),
        generate_headers = generate_headers,
    )

def _get_srcs(ctx):
    preprocessed_srcs = ctx.attr.preprocessed_srcs
    if preprocessed_srcs:
        if any([
            ctx.files.srcs,
            (hasattr(ctx.files, "hdrs") and ctx.files.hdrs),
            (hasattr(ctx.files, "exports") and ctx.files.exports),
            (hasattr(ctx.files, "string_srcs") and ctx.files.string_srcs),
            (hasattr(ctx.files, "exports_no_hdrs") and ctx.files.exports_no_hdrs),
        ]):
            fail("preprocessed_srcs and srcs, hdrs, exports, and string_srcs cannot be used together")
        srcs = preprocessed_srcs[DSourceInfo].srcs
        hdrs = preprocessed_srcs[DSourceInfo].hdrs
        exports = preprocessed_srcs[DSourceInfo].exports
        exports_no_hdrs = preprocessed_srcs[DSourceInfo].exports_no_hdrs
        string_srcs = preprocessed_srcs[DSourceInfo].string_srcs
        source_map = preprocessed_srcs[DSourceInfo].source_map
    else:
        srcs = ctx.files.srcs
        hdrs = ctx.files.hdrs if hasattr(ctx.files, "hdrs") else []
        exports = ctx.files.exports if hasattr(ctx.files, "exports") else []
        exports_no_hdrs = ctx.files.exports_no_hdrs if hasattr(ctx.files, "exports_no_hdrs") else []
        string_srcs = ctx.files.string_srcs if hasattr(ctx.files, "string_srcs") else []
        source_map = {}
    return srcs, hdrs, exports, exports_no_hdrs, string_srcs, source_map

def _candidate_path(f):
    # A directory stays a used input: -makedeps lists the files read under it, never the directory.
    return None if f.is_directory else f.path

def _compilation_impl(ctx, target_type, config, toolchain, imports, string_imports, compiler_flags, versions, global_versions, all_d_deps, source_map):
    compilation_mode = ctx.var["COMPILATION_MODE"]
    single_object = config.single_object
    qualified_object_file_names = config.qualified_object_file_names
    compile_via_bc = config.compile_via_bc
    use_single_action = config.use_single_action
    project_root = config.project_root
    srcs, hdrs, exports, exports_no_hdrs, string_srcs, _unused_source_map = _get_srcs(ctx)
    args = ctx.actions.args()

    # Apply compiler flags in order: toolchain common, toolchain per-mode, user flags
    if toolchain.compiler_flags:
        args.add_all(toolchain.compiler_flags)

    if toolchain.compiler_flags_per_mode and compilation_mode in toolchain.compiler_flags_per_mode:
        args.add_all(toolchain.compiler_flags_per_mode[compilation_mode])

    for src in srcs:
        if src in source_map:
            args.add(source_map[src])
        else:
            args.add(src)
    args.add_all(imports.to_list(), format_each = "-I=%s")
    args.add_all(string_imports.to_list(), format_each = "-J=%s")
    args.add_all(compiler_flags.to_list())

    # Use version_flag from toolchain config
    version_flag = toolchain.version_flag if toolchain.version_flag else "-version="
    args.add_all(global_versions + versions.to_list(), format_each = version_flag + "%s")
    # Apply feature flags defined by the toolchain.  Feature flags are resolved
    # per-target from ctx.attr.d_features and are NOT stored in DInfo, so they
    # cannot propagate transitively the way dopts can.
    feature_flags = toolchain.feature_flags if hasattr(toolchain, "feature_flags") else {}
    if feature_flags:
        effective_features = list(ctx.features) + [
            f for f in ctx.attr.d_features
            if f not in ctx.features
        ]
        for feature in effective_features:
            if feature in feature_flags:
                args.add_all(feature_flags[feature])

    output = None
    if target_type == TARGET_TYPE.TEST:
        args.add("-unittest")
        if ctx.attr.add_main:
            args.add("-main")
    if target_type == TARGET_TYPE.LIBRARY:
        # Always use lib_flags to create archive
        args.add_all(toolchain.lib_flags)

        if single_object:
            args.add(toolchain.single_obj_flag)

        # Add --oq flag if qualified object file names are enabled
        if qualified_object_file_names:
            args.add("--oq")

        output = ctx.actions.declare_file(static_library_name(ctx, ctx.label.name))
        library_to_link = None if ctx.attr.source_only else cc_common.create_library_to_link(
            actions = ctx.actions,
            static_library = output,
            alwayslink = ctx.attr.alwayslink,
        )
    else:
        # Binary and test targets: compile to object file with -c
        args.add("-c")
        output = ctx.actions.declare_file(object_file_name(ctx, ctx.label.name))
        library_to_link = None

    if compile_via_bc:
        # Add bitcode flags
        args.add_all(toolchain.output_bc_flags)

    # Unified compilation using ldc_wrapper.sh
    wrapper_script = ctx.attr._ldc_wrapper_script[DefaultInfo].files.to_list()[0]

    source_map_file = None
    if source_map:
        source_map_file = write_source_map(ctx, source_map)

    # Prepare environment variables for wrapper
    env = dict(ctx.var)
    env["LDC2_REAL"] = toolchain.d_compiler[DefaultInfo].files_to_run.executable.path
    env["D_TARGET"] = "%s" % ctx.label
    if source_map_file:
        env["LDC2_SOURCE_MAP"] = source_map_file.path
    if toolchain.debug_repo_root_override:
        env["LDC2_DEBUG_REPO_ROOT_OVERRIDE"] = toolchain.debug_repo_root_override

    # Exact deps: the wrapper lists the dependency files (D sources and string-import files) the compile did not
    # read. The candidates file itself stays in the key: a file added to a dependency can satisfy an import or a
    # string import that found no file (one in __traits(compiles) does not fail the compile).
    candidates = []
    unused_inputs = None
    if ctx.attr._exact_deps[BuildSettingInfo].value:
        candidates_file = ctx.actions.declare_file(ctx.label.name + ".d_candidates")
        candidate_lines = ctx.actions.args()
        candidate_lines.set_param_file_format("multiline")
        candidate_lines.add_all(depset(transitive = [d.interface_srcs for d in all_d_deps]), map_each = _candidate_path)
        ctx.actions.write(candidates_file, candidate_lines)
        unused_inputs = ctx.actions.declare_file(ctx.label.name + ".unused_inputs")
        env["D_EXACT_DEPS_CANDIDATES"] = candidates_file.path
        env["D_EXACT_DEPS_UNUSED"] = unused_inputs.path
        candidates = [candidates_file]

    inputs = depset(
        direct = (srcs + string_srcs + hdrs + exports + exports_no_hdrs + [wrapper_script] + ([source_map_file] if source_map_file else []) + candidates),
        transitive = [toolchain.d_compiler[DefaultInfo].default_runfiles.files] +
                     [d.interface_srcs for d in all_d_deps],
    )

    # Declare bitcode object files if compiling via bitcode
    bc_objs = []
    bc_archive = None
    bc_obj = None
    bc_library_to_link = None
    compile_output = output  # By default, compile directly to output
    if compile_via_bc:
        if target_type == TARGET_TYPE.LIBRARY:
            # For libraries: compile to bitcode archive
            bc_archive = ctx.actions.declare_file(static_library_name(ctx, ctx.label.name + ".bc"))
            bc_library_to_link = None if ctx.attr.source_only else cc_common.create_library_to_link(
                actions = ctx.actions,
                static_library = bc_archive,
                alwayslink = ctx.attr.alwayslink,
            )
            compile_output = bc_archive

            if use_single_action:
                # Single-action mode: don't unpack, llc_archive_compiler will handle it
                env["LDC_SKIP_UNPACK"] = "1"
            else:
                # Parallel mode: compute and declare individual bitcode object files
                obj_names = compute_object_file_names(ctx, srcs, qualified_object_file_names, project_root, source_map)
                for src, obj_name in obj_names.items():
                    bc_obj_file = ctx.actions.declare_file(ctx.label.name + "_bc_objs/" + obj_name)
                    bc_objs.append(bc_obj_file)

                # Set BC_UNPACK_DIR for wrapper to unpack archive
                bc_unpack_dir = bc_objs[0].dirname if bc_objs else ""
                env["BC_UNPACK_DIR"] = bc_unpack_dir

            # Set AR_CMD: use toolchain ar_tool if available, otherwise system ar
            if toolchain.ar_tool:
                env["AR_CMD"] = toolchain.ar_tool[DefaultInfo].files_to_run.executable.path
            else:
                env["AR_CMD"] = "ar"
        else:
            # For binaries/tests: compile to single bitcode object file
            bc_obj = ctx.actions.declare_file(object_file_name(ctx, ctx.label.name + ".bc"))
            compile_output = bc_obj

    # Stage 1: Compile (and optionally unpack if bitcode)
    args.add(compile_output, format = "-of=%s")
    outputs = [compile_output] + bc_objs
    tools = [toolchain.d_compiler[DefaultInfo].files_to_run]
    # Add ar_tool to tools if using it for unpacking
    if compile_via_bc and toolchain.ar_tool:
        tools.append(toolchain.ar_tool[DefaultInfo].files_to_run)
    if unused_inputs:
        outputs.append(unused_inputs)

    ctx.actions.run(
        inputs = inputs,
        outputs = outputs,
        executable = wrapper_script,
        arguments = [args],
        tools = tools,
        env = env,
        use_default_shell_env = False,
        mnemonic = "Dcompile",
        progress_message = "Compiling D %s %s" % (target_type, ctx.label.name),
        unused_inputs_list = unused_inputs,
    )

    # Stage 2 & 3: Bitcode to native compilation and repacking (if bitcode enabled)
    if compile_via_bc:
        if use_single_action:
            # Single-action mode: compile .bc.o or unpack/compile/pack .bc.a
            compile_bitcode_single_action(ctx, toolchain, bc_obj, bc_archive, output)
        else:
            # Parallel mode: Stage 2 - Compile bitcode objects to native
            native_objs = compile_bitcode_to_native(ctx, toolchain, bc_objs)

            # Stage 3: Repack native objects into final archive (only if not single-action)
            if native_objs:
                repack_native_objects(ctx, toolchain, native_objs, output)

    return struct(
        native_object = output,
        native_library_to_link = library_to_link,
        bc_object = bc_obj,
        bc_library_to_link = bc_library_to_link,
    )

def compilation_action(ctx, target_type = TARGET_TYPE.LIBRARY, cycle_breaker = False, cycle_breaker_lib = None):
    """Defines a compilation action for D source files.

    Args:
        ctx: The rule context.
        target_type: The type of the target, either 'binary', 'library', or 'test'.
        cycle_breaker: If true, the library is a cycle breaker. It will only generate headers and compute _this lib's_ exported files.
        cycle_breaker_lib: Label of the cycle breaker library for this library. If specified, this library will skip header generation
            and take _this lib's_ exported files from the cycle breaker library.
    Returns:
        The DInfo provider containing the compilation information.
    """
    toolchain = ctx.toolchains["//d:toolchain_type"].d_toolchain_info
    srcs, hdrs, exports, exports_no_hdrs, string_srcs, source_map = _get_srcs(ctx)
    config = _compilation_config_from_ctx(ctx, target_type, srcs)
    compile_via_bc = config.compile_via_bc
    generate_headers = config.generate_headers

    # Compute project root and validate sources
    project_root = compute_project_root(ctx, ctx.attr.project_root)
    if srcs:
        validate_sources_under_project_root(ctx, srcs, project_root, source_map)

    # Compute import base path for DInfo propagation
    # When project_root is empty string, it means repository root
    import_base_path = paths.join(ctx.label.workspace_root, project_root) if project_root else ctx.label.workspace_root

    flattened_deps = []
    for d in ctx.attr.deps:
        if DDepsInfo not in d:
            flattened_deps.append(d)
        else:
            flattened_deps.extend(d[DDepsInfo].deps)
    # Regular dependencies (propagated to consumers)
    c_deps = [d[CcInfo] for d in flattened_deps if CcInfo in d]
    d_deps = [d[DInfo] for d in flattened_deps if DInfo in d]

    # Implementation dependencies (not propagated to consumers)
    impl_c_deps = []
    impl_d_deps = []
    if hasattr(ctx.attr, "implementation_deps") and ctx.attr.implementation_deps:
        flattened_impl_deps = []
        for d in ctx.attr.implementation_deps:
            if DDepsInfo not in d:
                flattened_impl_deps.append(d)
            else:
                flattened_impl_deps.extend(d[DDepsInfo].deps)
        impl_c_deps = [d[CcInfo] for d in flattened_impl_deps if CcInfo in d]
        impl_d_deps = [d[DInfo] for d in flattened_impl_deps if DInfo in d]

    # Link-only dependencies: object code transits to the final binary, but
    # the interface is NOT added to compile inputs and NOT propagated to
    # consumers. Gathered separately so they never enter all_*_deps (compile)
    # nor the propagated interface_srcs — only the linking_context below.
    linkonly_c_deps = []
    linkonly_d_deps = []
    if hasattr(ctx.attr, "link_only_deps") and ctx.attr.link_only_deps:
        flattened_linkonly_deps = []
        for d in ctx.attr.link_only_deps:
            if DDepsInfo not in d:
                flattened_linkonly_deps.append(d)
            else:
                flattened_linkonly_deps.extend(d[DDepsInfo].deps)
        linkonly_c_deps = [d[CcInfo] for d in flattened_linkonly_deps if CcInfo in d]
        linkonly_d_deps = [d[DInfo] for d in flattened_linkonly_deps if DInfo in d]

    # For compilation: use ALL deps (regular + implementation). link_only_deps
    # are deliberately excluded — they contribute object code only.
    all_c_deps = c_deps + impl_c_deps
    all_d_deps = d_deps + impl_d_deps

    # Collect from all deps for compilation
    compiler_flags = depset(
        ctx.attr.dopts,
        transitive = [d.compiler_flags for d in all_d_deps],
    )
    # Use project_root for imports instead of package path
    pkg_path = paths.join(ctx.label.workspace_root, ctx.label.package)
    imports = depset(
        ([import_base_path] if import_base_path else []) +
        [paths.join(ctx.label.workspace_root, ctx.label.package, imp) for imp in ctx.attr.imports],
        transitive = [d.imports for d in all_d_deps],
    )
    string_imports = depset(
        ([pkg_path] if pkg_path and string_srcs else []) +
        [paths.join(ctx.label.workspace_root, ctx.label.package, imp) for imp in ctx.attr.string_imports],
        transitive = [d.string_imports for d in all_d_deps],
    )

    # Collect global versions from toolchain
    global_versions = []
    if hasattr(toolchain, "global_versions_common") and toolchain.global_versions_common:
        global_versions.extend(toolchain.global_versions_common)

    compilation_mode = ctx.var["COMPILATION_MODE"]
    if (hasattr(toolchain, "global_versions_per_mode") and
        toolchain.global_versions_per_mode and
        compilation_mode in toolchain.global_versions_per_mode):
        global_versions.extend(toolchain.global_versions_per_mode[compilation_mode])

    versions = depset(
        ctx.attr.versions,
        transitive = [d.versions for d in all_d_deps],
    )

    # Determine which sources to export (libraries only)
    direct_interface_srcs = srcs
    interface_source_map = source_map  # Source map for the exported bits
    to_hdrgen = srcs

    if target_type == TARGET_TYPE.LIBRARY:
        if cycle_breaker_lib:
            direct_interface_srcs = cycle_breaker_lib[DInfo].interface_srcs.to_list()
            interface_source_map = cycle_breaker_lib[DInfo].source_map
        else:
            # Priority: if either of hdrs, exports is specified, use them.
            # Otherwise export all srcs (backward compatibility)
            public_srcs = []
            if hdrs:
                public_srcs.extend(hdrs)
                to_hdrgen = []
            if exports:
                public_srcs.extend(exports)
                to_hdrgen = exports
            # If no hdrs/exports specified, use all srcs (backward compatibility)
            if public_srcs:
                direct_interface_srcs = public_srcs
            if generate_headers:
                genhdrs, interface_source_map = generate_headers_action(ctx, toolchain, to_hdrgen, exports_no_hdrs, interface_source_map)
                direct_interface_srcs = hdrs + genhdrs + exports_no_hdrs
            interface_source_map = filter_source_map(interface_source_map, direct_interface_srcs)
    deps_source_map = merge_source_maps([d.source_map for d in all_d_deps])
    our_source_map = merge_source_maps([source_map, deps_source_map])
    export_source_map = merge_source_maps([interface_source_map, deps_source_map])

    # Check if this is a header-only or deps-only library (no srcs to compile)
    has_srcs = len(srcs) > 0

    library_to_link = None
    output = None
    bc_output = None
    bc_library_to_link = None
    # Skip compilation if no sources (header-only or deps-only library)
    if has_srcs and not cycle_breaker:
        compilation_result = _compilation_impl(ctx, target_type, config, toolchain, imports, string_imports, compiler_flags, versions, global_versions, all_d_deps, our_source_map)
        library_to_link = compilation_result.native_library_to_link
        output = compilation_result.native_object
        bc_output = compilation_result.bc_object
        bc_library_to_link = compilation_result.bc_library_to_link

    # Expand $(location ...) / $(execpath ...) / $(rootpath ...) against the
    # rule's additional_linker_inputs (matching cc_library.linkopts semantics).
    # Done here so the expanded form propagates through both linker_input.user_link_flags
    # and DInfo.linker_flags, avoiding double-add in link.bzl.
    expanded_linkopts = [
        ctx.expand_location(opt, targets = getattr(ctx.attr, "additional_linker_inputs", []))
        for opt in ctx.attr.linkopts
    ]
    linker_input = None
    if library_to_link:
        linker_input = cc_common.create_linker_input(
            owner = ctx.label,
            libraries = depset(direct = [library_to_link] if library_to_link else None),
            user_link_flags = expanded_linkopts,
        )
    bc_linker_input = linker_input
    if bc_library_to_link:
        bc_linker_input = cc_common.create_linker_input(
            owner = ctx.label,
            libraries = depset(direct = [bc_library_to_link] if bc_library_to_link else None),
            user_link_flags = expanded_linkopts,
        )
    linking_context = cc_common.create_linking_context(
        linker_inputs = depset(
            direct = [linker_input] if linker_input else None,
            transitive = [
                d.linking_context.linker_inputs
                for d in all_c_deps + all_d_deps + linkonly_c_deps + linkonly_d_deps
            ],
        ),
    )
    bc_linking_context = cc_common.create_linking_context(
        linker_inputs = depset(
            direct = [bc_linker_input] if bc_linker_input else None,
            transitive = [
                d.bc_linking_context.linker_inputs
                for d in all_d_deps + linkonly_d_deps
            ] + [d.linking_context.linker_inputs for d in all_c_deps + linkonly_c_deps],
        ),
    )
    # For DInfo propagation: use only regular deps (not implementation deps)
    return DInfo(
        bc_output = bc_output,
        bc_linking_context = bc_linking_context,
        compilation_output = output,
        compiler_flags = compiler_flags, # TODO: revisit this, is accumulating flags a good idea?
        imports = imports,
        interface_srcs = depset(
            direct_interface_srcs + ctx.files.string_srcs,
            transitive = [d.interface_srcs for d in d_deps],  # Only regular deps
        ),
        linking_context = linking_context,  # Already includes all deps internally
        linker_flags = depset(
            expanded_linkopts,
            transitive = [d.linker_flags for d in d_deps],  # Only regular deps
        ),
        source_map = export_source_map,
        source_only = ctx.attr.source_only if target_type == TARGET_TYPE.LIBRARY else False,
        string_imports = string_imports,
        versions = versions,
        libs_bc = depset(
            direct = [output] if (output and target_type == TARGET_TYPE.LIBRARY and compile_via_bc and not ctx.attr.source_only) else [],
            transitive = [d.libs_bc for d in d_deps if hasattr(d, "libs_bc")],
        ),
        libs_non_bc = depset(
            direct = [output] if (output and target_type == TARGET_TYPE.LIBRARY and not compile_via_bc and not ctx.attr.source_only) else [],
            transitive = [d.libs_non_bc for d in d_deps if hasattr(d, "libs_non_bc")],
        ),
    )
