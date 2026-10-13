"""Body-use cutoff for D compiles.

A D compile depends on the function bodies of an imported module only when it analyses them. With the
cutoff on, every library computes a digest of each interface source that leaves out the bodies, and
every compile reports through unused_inputs_list the imported sources whose bodies it never analysed (per
its time trace, or the -body-use= report of a patched LDC): those stay in the action's key only through
their digests. Editing such a body then
re-runs only the compiles that analyse it. Details: d/private/tools/ifc_digest/ifc_digest.d.

Bazel honours unused_inputs_list in its local action cache, not in remote cache keys.

The cutoff assumes no cross-module inlining; ldc_wrapper.sh prunes nothing for a command line that
optimizes or inlines. Turn it on by pointing the @rules_d//:ifc_digest flag at an ifc_digest_tool target.
"""

load("//d/private:providers.bzl", "IfcDigestInfo")

def _ifc_digest_tool_impl(ctx):
    if not ctx.attr.tool:
        return [IfcDigestInfo(tool = None, names = depset(), body_use = False)]
    tool = ctx.attr.tool[DefaultInfo].files_to_run
    if not ctx.toolchains["//d:toolchain_type"]:
        return [IfcDigestInfo(tool = tool, names = depset(), body_use = ctx.attr.body_use)]
    toolchain = ctx.toolchains["//d:toolchain_type"].d_toolchain_info
    toolchain_srcs = [
        f
        for f in toolchain.d_compiler[DefaultInfo].default_runfiles.files.to_list()
        if f.extension in ("d", "di")
    ]
    names = ctx.actions.declare_file(ctx.label.name + ".toolchain_names")
    args = ctx.actions.args()
    args.add("names")
    args.add(names, format = "--out=%s")
    args.add_all(toolchain_srcs)
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    ctx.actions.run(
        executable = tool,
        arguments = [args],
        inputs = toolchain_srcs,
        outputs = [names],
        mnemonic = "DIfcNames",
        progress_message = "Collecting the line-capturing names of the D toolchain's sources",
    )
    return [IfcDigestInfo(tool = tool, names = depset([names]), body_use = ctx.attr.body_use)]

ifc_digest_tool = rule(
    implementation = _ifc_digest_tool_impl,
    doc = "The body-use cutoff's tool. Without `tool`, the cutoff is off.",
    attrs = {
        "tool": attr.label(
            doc = "The ifc_digest executable (d/private/tools/ifc_digest/ifc_digest.d).",
            executable = True,
            allow_files = True,
            cfg = "exec",
        ),
        "body_use": attr.bool(
            doc = "The D compiler has LDC's -body-use= option (weka/ldc branch body-use): compiles " +
                  "report body use through it instead of through a time trace.",
        ),
    },
    toolchains = [config_common.toolchain_type("//d:toolchain_type", mandatory = False)],
    provides = [IfcDigestInfo],
)
