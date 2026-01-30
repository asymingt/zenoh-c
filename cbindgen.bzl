# Copyright 2019 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Adapted from https://github.com/bazelbuild/rules_rust/pull/392

load("@rules_rust//rust:rust_common.bzl", "CrateInfo", "DepInfo")
load("@rules_rust//cargo:cargo_manifest.bzl", "CargoManifestInfo", "cargo_manifest_aspect")

_rust_cbindgen_library_doc = """\
Generate C/C++ bindings to Rust code from `rust_library` targets

`cbindgen` (see https://crates.io/crates/cbindgen) is a tool for generating C bindings to Rust code. This rule \
allows for `rust_library` targets that have also specified `cdylib` or `staticlib` as their `crate_type` to \
generate C/C++ bindings to be used in other rules that otherwise expect `cc_library` targets.

Note that in order to use these rules, the following snippet must be added to your projects `WORKSPACE.bazel` file:

```python
load("@io_bazel_rules_rust//cbindgen:repositories.bzl", "rust_cbindgen_repositories")

rust_cbindgen_repositories()
```

Basic Example:

Below demonstrates a `rust_cbindgen_library` target being used with a `cc_binary` target. More thorough examples can \
be seen in the `examples/cbindgen` directory of the `rules_rust` repository.

```python
rust_library(
    name = "lib",
    crate_type = "staticlib",
)

rust_cbindgen_library(
    name = "lib_cbindgen",
    lib = ":lib",
)

cc_binary(
    name = "bin",
    srcs = ["main.cc"],
    deps = [":lib_cbindgen"],
)
```
"""

def _rust_cbindgen_library_impl(ctx):
    """'rust_cbindgen' rule implementation

    Args:
        ctx: A context object that is passed to the implementation function for a rule or aspect.
    Returns:
        (list) a list of Providers
    """

    # Ensure the target lib is compatible with this rule.
    rust_lib = ctx.attr.lib
    supported_crate_types = ["cdylib", "staticlib"]
    if not rust_lib[CrateInfo].type in supported_crate_types:
        fail("Rust library '{}' of type '{}' must be one of {}".format(
            rust_lib.label,
            rust_lib[CrateInfo].type,
            supported_crate_types,
        ))

    # Determine the location of the cbindgen executable
    toolchain = ctx.toolchains["@io_bazel_rules_rust//cbindgen:cbindgen_toolchain"]
    cbindgen_bin = toolchain.cbindgen

    # Optionally use the user defined template if one is provided
    if ctx.file.config:
        template_config = ctx.file.config
        substitutions = ctx.attr.substitutions
    else:
        if ctx.attr.substitutions:
            fail("'substitutions' should not be defined without the `config` attribute also being defined.")

        # Identify the desired language
        use_c = ctx.attr.lang in ["c"]
        use_cpp = ctx.attr.lang in ["cc", "c++", "cxx"]

        if use_c and use_cpp:
            fail("The use of C/C++ must be mutually exclusive")

        template_config = ctx.file._config_default_template

        # Direct dependents
        substitutions = {
            "{label}": str(ctx.label),
            "{language}": "C" if use_c else "C++",
            "{include_guard}": "INCLUDE_{}_H".format(ctx.label.name.upper()),
            "{namespace}": "namespace = \"{}\"".format(ctx.label.name) if use_cpp else "",
        }

    # Generate the `cbindgen.toml` config file
    ctx.actions.expand_template(
        template = template_config,
        output = ctx.outputs.config,
        substitutions = substitutions,
    )

    output_header = ctx.actions.declare_file(
        ctx.attr.header_name if ctx.attr.header_name else "{}.h".format(ctx.label.name),
    )

    args = ctx.actions.args()
    args.add("--config")
    args.add(ctx.outputs.config)
    args.add("--output")
    args.add(output_header)
    args.add(rust_lib[CargoManifestInfo].toml.dirname)

    inputs = depset(
        rust_lib[CrateInfo].srcs + [ctx.outputs.config],
        transitive = [
            rust_lib[OutputGroupInfo].all_files,
            depset(transitive = [
                depset(dep[CrateInfo].srcs)
                for dep in rust_lib[CrateInfo].deps
            ]),
        ],
    )

    rust_toolchain = ctx.toolchains["@io_bazel_rules_rust//rust:toolchain"]
    env = {
        "CARGO": rust_toolchain.cargo.path,
        "HOST": rust_toolchain.exec_triple,
        "RUSTC": rust_toolchain.rustc.path,
        "TARGET": rust_toolchain.target_triple,
    }

    tools = depset(
        [
            rust_toolchain.cargo,
            rust_toolchain.rustc,
        ],
        transitive = [
            rust_toolchain.rustc_lib.files,
            rust_toolchain.rust_lib.files,
        ],
    )

    ctx.actions.run(
        mnemonic = "RustCbindgen",
        progress_message = "Generating {} bindings for '{}'..".format(
            ctx.attr.lang.upper(),
            output_header.short_path,
        ),
        outputs = [output_header],
        executable = cbindgen_bin,
        inputs = inputs,
        arguments = [args],
        tools = tools,
        env = env,
    )

    rust_compilation_context = rust_lib[CcInfo].compilation_context

    # Add the new headers to the existing CompilationContext info
    compilation_context = cc_common.create_compilation_context(
        headers = depset([output_header], transitive = [rust_compilation_context.headers]),
        defines = rust_compilation_context.defines,
        framework_includes = rust_compilation_context.framework_includes,
        includes = rust_compilation_context.includes,
        local_defines = rust_compilation_context.local_defines,
        quote_includes = rust_compilation_context.quote_includes,
        system_includes = rust_compilation_context.system_includes,
    )

    # Return all providers given by `cc_library` and `rust_library` to ensure
    # compatiblity with other rules
    return [
        rust_lib[CrateInfo],
        rust_lib[DepInfo],
        CcInfo(
            compilation_context = compilation_context,
            linking_context = rust_lib[CcInfo].linking_context,
        ),
        DefaultInfo(
            files = depset([output_header], transitive = [rust_lib.files]),
            runfiles = ctx.runfiles([output_header], transitive_files = rust_lib.files),
        ),
    ]

rust_cbindgen_library = rule(
    implementation = _rust_cbindgen_library_impl,
    doc = _rust_cbindgen_library_doc,
    attrs = {
        "lib": attr.label(
            doc = (
                "The `rust_library` target from which to run cbindgen on. " +
                "The `crate_type` of the target passed here must be " +
                "either `cdylib` or `staticlib`."
            ),
            providers = [CrateInfo, CcInfo],
            aspects = [cargo_manifest_aspect],
            mandatory = True,
        ),
        "cbindgen_flags": attr.string_list(
            doc = (
                "Optional flags to pass directly to the bindgen executable. " +
                "See https://docs.rs/cbindgen/latest/cbindgen/ for details."
            ),
        ),
        "header_name": attr.string(
            doc = (
                "Optional override for the name of the generated header. The default is the " +
                "name of the target created by this rule."
            ),
        ),
        "lang": attr.string(
            doc = "Optional target language identifier of the generated header file",
            values = [
                "c",
                "cc",
                "c++",
                "cxx",
            ],
            default = "cc",
        ),
        "config": attr.label(
            doc = "Optional Cbindgen configuration template",
            allow_single_file = True,
        ),
        "substitutions": attr.string_dict(
            doc = "Optional substitutions for the cbindgen config template passed to `config`",
        ),
        "_config_default_template": attr.label(
            doc = "Default cbindgen configuration template. This is treated as fallback from `config`",
            default = Label("//cbindgen:private/cbindgen.toml.template"),
            allow_single_file = True,
        ),
    },
    outputs = {
        "config": "%{name}.cbindgen.toml",
    },
    toolchains = [
        "@io_bazel_rules_rust//cbindgen:cbindgen_toolchain",
        "@io_bazel_rules_rust//rust:toolchain",
    ],
)
