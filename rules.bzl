# Copyright 2025 Open Source Robotics Foundation, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("@rules_rust//rust:rust_common.bzl", "CrateInfo")

def _rust_cbindgen_impl(ctx):
    
    # This is a list of File objects, even with allow_single_file=True.
    config_file = ctx.files.config[0]

    # Assemble arguments to cbindgen.
    args = ctx.actions.args()
    args.add("--config")
    args.add(config_file.path)
    args.add("--output")
    args.add(ctx.outputs.header.path)
    args.add(config_file.dirname)

    # Find the tooling required to provide the deps.
    rust_toolchain = ctx.toolchains["@rules_rust//rust:toolchain"]

    # Correctly collect CrateInfo providers from all deps.
    crate_infos = [dep[CrateInfo] for dep in ctx.attr.deps]

    # Collect all transitive files (not just rlibs) to make them available
    # in the sandbox. This includes .rlib, .so, .d, etc.
    all_inputs = depset(
        ctx.files.srcs + [config_file],
        transitive = [
            dep[CrateInfo].transitive_all_files
                for dep in ctx.attr.deps if CrateInfo in dep
        ],
    )

    # This creates the necessary `--extern` and `-L` flags.
    # rustflags = rust_common.get_rust_flags(crate_infos = crate_infos)

    # Set the environment.
    env = {
        "CARGO": rust_toolchain.cargo.path,
        "HOST": rust_toolchain.exec_triple.str,
        "RUSTC": rust_toolchain.rustc.path,
        "TARGET": rust_toolchain.target_triple.str,
        #"RUSTFLAGS": " ".join(rustflags),
    }

    # Run cbindgen.
    ctx.actions.run(
        mnemonic = "RustCBindgen",
        progress_message = "Calling cbindgen for '{}'".format(ctx.outputs.header.short_path),
        outputs = [ctx.outputs.header],
        executable = ctx.executable._cbindgen,
        inputs = all_inputs,
        arguments = [args],
        tools = depset([rust_toolchain.cargo, rust_toolchain.rustc]),
        env = env,
    )

    # Return the generated header.
    return [DefaultInfo(files = depset([ctx.outputs.header]))]

rust_cbindgen = rule(
    implementation = _rust_cbindgen_impl,
    attrs = {
        "config": attr.label(
            doc = "Mandatory cbindgen configuration template",
            allow_single_file = True,
            mandatory = True,
        ),
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "The list of source files to concatenate.",
        ),
        "deps": attr.label_list(
            providers = [CrateInfo],
            doc = "A list of direct Rust dependencies.",
        ),
        "header": attr.output(
            mandatory = True,
            doc = "The output header file.",
        ),
        "_cbindgen": attr.label(
            default = Label("@crate//:cbindgen__cbindgen"),
            executable = True,
            cfg = "exec",
            doc = "The cbindgen executable.",
        ),
    },
    toolchains = ["@rules_rust//rust:toolchain"],
)
