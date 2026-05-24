#![cfg(target_os = "windows")]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

struct Case {
    name: &'static str,
    exit_code: i32,
    stdout: &'static str,
    deps: &'static [&'static str],
    args: &'static [&'static str],
}

const TL_EMIT_PROGRAM_ASM: &str = concat!(
    "    .text\n",
    "    .globl main\n",
    "    .globl _start\n",
    "\n",
    "main:\n",
    "    push %rbp\n",
    "    mov %rsp, %rbp\n",
    "    movq $1, %rax\n",
    "    pushq %rax\n",
    "    movq $2, %rax\n",
    "    pushq %rax\n",
    "    movq $3, %rax\n",
    "    movq %rax, %rcx\n",
    "    popq %rax\n",
    "    imulq %rcx, %rax\n",
    "    movq %rax, %rcx\n",
    "    popq %rax\n",
    "    addq %rcx, %rax\n",
    "    pop %rbp\n",
    "    ret\n",
    "\n",
    "_start:\n",
    "    call main\n",
    "    movq %rax, %rdi\n",
    "    movq $60, %rax\n",
    "    syscall\n",
);

#[test]
fn windows_target_compiles_links_and_runs_native_executables() {
    for case in native_cases() {
        run_case(&case);
    }
}

#[test]
fn selfhost_backend_windows_runtime_helpers_emit_assemble_link_and_run() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fixture_path = manifest_dir
        .join("selfhost")
        .join("compiler_backend_runtime_fixture.tl");
    let work_dir = manifest_dir
        .join("target")
        .join("windows-native-tests")
        .join("selfhost_backend_runtime_helpers");
    fs::create_dir_all(&work_dir).expect("create selfhost Windows runtime helper test dir");

    let asm_path = work_dir.join("runtime_helpers.s");
    let obj_path = work_dir.join("runtime_helpers.obj");
    let bin_path = work_dir.join("runtime_helpers.exe");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&fixture_path)
        .arg("--target")
        .arg("windows-x86_64")
        .arg("--")
        .arg(&asm_path)
        .arg("windows-x86_64")
        .output()
        .expect("run selfhost backend runtime fixture for Windows target");
    assert_eq!(
        output.status.code(),
        Some(0),
        "selfhost Windows runtime fixture failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let asm = fs::read_to_string(&asm_path)
        .expect("read selfhost Windows runtime helper assembly")
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    for snippet in [
        ".globl main\n",
        ".globl tl_alloc\n",
        "\ntl_alloc:\n",
        ".globl tl_oob_abort\n",
        "\ntl_oob_abort:\n",
        ".globl tl_substring\n",
        "\ntl_substring:\n",
        ".globl tl_string_concat\n",
        "\ntl_string_concat:\n",
        "\n.L_tl_read_stdin_line:\n",
        "\n.L_tl_read_stdin_bytes:\n",
        "\n.L_tl_stdin_eof:\n",
        "\n.L_tl_flush_stdout:\n",
        "    .extern malloc\n",
        "    .extern _write\n",
        "    .extern exit\n",
        "    .extern _read\n",
        "    .extern fflush\n",
        "    call malloc\n",
        "    call _write\n",
        "    call _read\n",
        "    call fflush\n",
    ] {
        assert!(
            asm.contains(snippet),
            "selfhost Windows runtime helper assembly missing {:?}:\n{}",
            snippet,
            asm
        );
    }
    assert!(!asm.contains("    syscall"), "asm:\n{}", asm);
    assert!(!asm.contains("\n_start:"), "asm:\n{}", asm);
    assert!(!asm.contains("tl_current_arena:"), "asm:\n{}", asm);
    for helper in [
        ".extern tl_alloc\n",
        ".extern tl_oob_abort\n",
        ".extern tl_substring\n",
        ".extern tl_string_concat\n",
        ".extern .L_tl_read_stdin_line\n",
        ".extern .L_tl_read_stdin_bytes\n",
        ".extern .L_tl_stdin_eof\n",
        ".extern .L_tl_flush_stdout\n",
    ] {
        assert!(
            !asm.contains(helper),
            "runtime helper should be defined inline, not extern: {helper}\n{asm}"
        );
    }

    let status = Command::new("clang")
        .arg("--target=x86_64-pc-windows-msvc")
        .arg("-c")
        .arg(&asm_path)
        .arg("-o")
        .arg(&obj_path)
        .status()
        .expect("assemble selfhost Windows runtime helper output");
    assert!(
        status.success(),
        "assembling selfhost Windows runtime helper output failed"
    );

    let status = Command::new("lld-link")
        .arg("/NOLOGO")
        .arg(&obj_path)
        .arg(format!("/OUT:{}", bin_path.display()))
        .arg("/SUBSYSTEM:CONSOLE")
        .arg("msvcrt.lib")
        .arg("legacy_stdio_definitions.lib")
        .status()
        .expect("link selfhost Windows runtime helper output");
    assert!(
        status.success(),
        "linking selfhost Windows runtime helper output failed"
    );

    let output = Command::new(&bin_path)
        .output()
        .expect("run selfhost Windows runtime helper binary");
    assert_eq!(
        output.status.code(),
        Some(42),
        "selfhost Windows runtime helper binary exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn native_cases() -> Vec<Case> {
    vec![
        case("hello", 42, ""),
        case("arithmetic", 47, ""),
        case("fixed_array", 42, ""),
        case_with_deps("format_doc_integration", 42, "", &["format_doc.tl"]),
        case_with_deps(
            "format_cst_integration",
            42,
            "",
            &["format_cst.tl", "format_tokens.tl"],
        ),
        case_with_deps(
            "format_core_integration",
            42,
            "",
            &[
                "format_core.tl",
                "format_cst.tl",
                "format_tokens.tl",
                "format_doc.tl",
            ],
        ),
        case_with_deps(
            "format_rules_integration",
            42,
            "",
            &[
                "format_rules.tl",
                "format_cst.tl",
                "format_tokens.tl",
                "format_doc.tl",
            ],
        ),
        case("factorial", 120, ""),
        case("fibonacci", 13, ""),
        case("global_initializer", 120, ""),
        case("aggregate_globals", 42, ""),
        case("control_flow", 15, ""),
        case("cond", 42, ""),
        case("spmd_foreach", 42, ""),
        case("functions", 32, ""),
        case("function_pointer_values", 42, ""),
        case("lambda_lift", 42, ""),
        case("lambda_aggregate_returns", 42, ""),
        case("print", 0, "42\nfalse\n"),
        case("print_char", 0, "A\n"),
        case("print_string", 0, "hello\nworld\n"),
        case("unit_functions", 7, ""),
        case("unit_main", 0, ""),
        case("tl_alloc", 0, ""),
        case("many_args", 36, ""),
        case("narrow_div_mod", 30, ""),
        case("overflow_casts", 0, ""),
        case("string_length", 5, ""),
        case("string_eq", 0, "true\nfalse\nfalse\ntrue\n"),
        case("string_match", 42, ""),
        case("substring", 33, ""),
        case("string_append", 0, "foobar\n"),
        case_with_deps("modules_main", 30, "", &["modules_helper.tl"]),
        case("enum_match", 42, ""),
        case("tuple_values", 42, ""),
        case("nullary_variant_call", 42, ""),
        case("lexer", 12, ""),
        case("enum_string_payload", 5, ""),
        case("maybe_result", 65, ""),
        case("tree", 3, ""),
        case("parser", 14, ""),
        case_with_deps("calc", 14, "", &["token.tl"]),
        case_with_deps(
            "tl_emit",
            0,
            TL_EMIT_PROGRAM_ASM,
            &["emit_core.tl", "ast_types.tl", "sym_i64_env.tl"],
        ),
        case_with_deps(
            "tl_ast",
            685,
            "",
            &["ast_types.tl", "read.tl", "lex.tl", "token.tl"],
        ),
        case_with_deps("tl_lexer", 19, "", &["lex.tl", "token.tl"]),
        case_with_deps("tl_reader", 62, "", &["lex.tl", "token.tl"]),
        case_with_deps(
            "tl_eval",
            30,
            "hello world3233\n25\n15\n2\n10\n1\n0\n1\n3\n(1 2 3)(1 (2 3) 4)(10 . 20)(1 2 . 3)(1 4 9 16)(1 2)",
            &["read.tl", "lex.tl", "token.tl"],
        ),
        case("nested_eval", 7, ""),
        case_with_deps(
            "sym_i64_env",
            0,
            "PASS: empty-miss\nPASS: single-hit-contains\nPASS: single-hit-value\nPASS: single-miss\nPASS: shadow-newest\nPASS: outer-preserved-a\nPASS: outer-no-b\nPASS: inner-sees-a\nPASS: inner-sees-b\nPASS: substring-key-hit\nPASS: append-key-hit\nPASS: chain-x\nPASS: chain-y\nPASS: chain-z\nAll sym-i64-env tests passed.\n",
            &["sym_i64_env_core.tl"],
        ),
        case_with_deps("text_buf", 0, "left-right\n", &["text_buf_core.tl"]),
        case_with_deps(
            "stdlib_string",
            42,
            "hello|\nhello|\nhello|\nfound\n|empty-left\n|empty-right\n|all-space\ncontains\nmissing\nhippo\nabx\n",
            &["stdlib/string.tl"],
        ),
        case_with_deps("stdlib_test", 42, "", &["stdlib/test.tl"]),
        case_with_deps("stdlib_io", 42, "", &["stdlib/io.tl"]),
        case_with_deps(
            "compiler_parse_smoke",
            42,
            "",
            &[
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        ),
        case_with_deps(
            "compiler_symbols_smoke",
            42,
            "",
            &[
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        ),
        case_with_deps(
            "compiler_typecheck_smoke",
            42,
            "",
            &[
                "compiler_typecheck.tl",
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        ),
        case_with_deps(
            "compiler_check_smoke",
            42,
            "",
            &[
                "compiler_check_core.tl",
                "compiler_load.tl",
                "compiler_typecheck.tl",
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        ),
        case_with_deps(
            "compiler_lower_smoke",
            42,
            "",
            &[
                "compiler_lower.tl",
                "compiler_ctfe.tl",
                "compiler_typecheck.tl",
                "compiler_ir_types.tl",
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        ),
        case_with_deps(
            "compiler_liveness_smoke",
            42,
            "",
            &[
                "compiler_liveness.tl",
                "compiler_ir_types.tl",
                "compiler_ast_types.tl",
            ],
        ),
        case_with_deps(
            "compiler_backend_smoke",
            42,
            "",
            &[
                "compiler_backend.tl",
                "compiler_regalloc.tl",
                "compiler_liveness.tl",
                "compiler_lower.tl",
                "compiler_ctfe.tl",
                "compiler_typecheck.tl",
                "compiler_ir_types.tl",
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
                "text_buf.tl",
            ],
        ),
        case_with_deps(
            "doc_extract_smoke",
            42,
            "",
            &["doc_extract.tl", "format_tokens.tl"],
        ),
        case_with_deps(
            "doc_test_smoke",
            42,
            "",
            &[
                "doc_test.tl",
                "compiler_check_core.tl",
                "compiler_load.tl",
                "compiler_typecheck.tl",
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "compiler_diagnostic.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        ),
        case_with_deps(
            "doc_render_smoke",
            42,
            "",
            &["doc_render.tl", "doc_extract.tl", "format_tokens.tl"],
        ),
        case_with_args("argv", 7, "alpha\n", &["alpha", "beta"]),
        // refs #538: fixtures mirrored from tests/integration.rs so the Windows
        // native suite tracks the Linux integration suite. Exit codes/deps match
        // the corresponding `Case` in integration.rs. (`with_region_*` stay
        // Linux-only by design — region reclaim is linux-x86_64 System V only.)
        case("comptime_scalar", 3, ""),
        case("f32_scalar", 42, ""),
        case("spmd_reduce_scalar", 42, ""),
        case("lambda_capture_scalar", 42, ""),
        case("lambda_capture_tuple", 42, ""),
        case("lambda_capture_aggregate", 42, ""),
        case("lambda_capture_struct_enum", 42, ""),
        case("lambda_capture_nested_aggregate", 42, ""),
        case("lambda_capture_fixed_array", 42, ""),
        case("lambda_capture_fixed_array_aggregate", 42, ""),
        case_with_deps("lex_span_smoke", 42, "", &["lex.tl", "token.tl"]),
        case_with_deps(
            "compiler_optimize_smoke",
            42,
            "",
            &[
                "compiler_optimize.tl",
                "compiler_ir_types.tl",
                "compiler_ast_types.tl",
            ],
        ),
        case_with_deps(
            "compiler_regalloc_smoke",
            42,
            "",
            &[
                "compiler_regalloc.tl",
                "compiler_liveness.tl",
                "compiler_ir_types.tl",
                "compiler_ast_types.tl",
            ],
        ),
    ]
}

fn case(name: &'static str, exit_code: i32, stdout: &'static str) -> Case {
    Case {
        name,
        exit_code,
        stdout,
        deps: &[],
        args: &[],
    }
}

fn case_with_deps(
    name: &'static str,
    exit_code: i32,
    stdout: &'static str,
    deps: &'static [&'static str],
) -> Case {
    Case {
        name,
        exit_code,
        stdout,
        deps,
        args: &[],
    }
}

fn case_with_args(
    name: &'static str,
    exit_code: i32,
    stdout: &'static str,
    args: &'static [&'static str],
) -> Case {
    Case {
        name,
        exit_code,
        stdout,
        deps: &[],
        args,
    }
}

fn run_case(case: &Case) {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = source_path_for_case(&manifest_dir, case.name);
    let work_dir = manifest_dir
        .join("target")
        .join("windows-native-tests")
        .join(case.name);
    fs::create_dir_all(&work_dir).expect("create Windows native test work dir");
    let work_path = work_dir.join(format!("{}.tl", case.name));
    copy_tl_source(&source_path, &work_path);

    let source_dir = source_path.parent().expect("case source path has parent");
    copy_case_deps(&manifest_dir, source_dir, &work_dir, case.deps);

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .arg("--target")
        .arg("windows-x86_64")
        .args(case.args)
        .output()
        .expect("run typelisp Windows native case");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(case.exit_code),
        "{} exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        case.name,
        stdout,
        stderr,
    );
    let expected_stdout = case.stdout.replace('\n', "\r\n");
    assert_eq!(
        stdout, expected_stdout,
        "{} stdout differed\nstderr:\n{}",
        case.name, stderr,
    );
    assert_eq!(stderr, "", "{} wrote stderr", case.name);
}

fn source_path_for_case(manifest_dir: &Path, name: &str) -> PathBuf {
    let integration_path = manifest_dir
        .join("tests")
        .join("integration")
        .join(format!("{name}.tl"));
    if integration_path.exists() {
        return integration_path;
    }

    let selfhost_file = match name {
        "tl_ast" => "ast.tl",
        "tl_emit" => "emit.tl",
        "tl_eval" => "eval.tl",
        "tl_lexer" => "lexer.tl",
        "tl_reader" => "reader.tl",
        "compiler_parse_smoke" => "compiler_parse_smoke.tl",
        "compiler_symbols_smoke" => "compiler_symbols_smoke.tl",
        "compiler_typecheck_smoke" => "compiler_typecheck_smoke.tl",
        "compiler_check_smoke" => "compiler_check_smoke.tl",
        "compiler_lower_smoke" => "compiler_lower_smoke.tl",
        "compiler_liveness_smoke" => "compiler_liveness_smoke.tl",
        "compiler_optimize_smoke" => "compiler_optimize_smoke.tl",
        "compiler_regalloc_smoke" => "compiler_regalloc_smoke.tl",
        "compiler_backend_smoke" => "compiler_backend_smoke.tl",
        "lex_span_smoke" => "lex_span_smoke.tl",
        "doc_extract_smoke" => "doc_extract_smoke.tl",
        "doc_test_smoke" => "doc_test_smoke.tl",
        "doc_render_smoke" => "doc_render_smoke.tl",
        _ => panic!("no TypeLisp source path configured for Windows native case {name}"),
    };
    manifest_dir.join("selfhost").join(selfhost_file)
}

fn dep_source_path(manifest_dir: &Path, source_dir: &Path, dep: &str) -> PathBuf {
    match dep {
        "sym_i64_env_core.tl" => manifest_dir.join("selfhost").join("sym_i64_env.tl"),
        "format_doc.tl" => manifest_dir.join("selfhost").join("format_doc.tl"),
        "format_cst.tl" => manifest_dir.join("selfhost").join("format_cst.tl"),
        "format_core.tl" => manifest_dir.join("selfhost").join("format_core.tl"),
        "format_rules.tl" => manifest_dir.join("selfhost").join("format_rules.tl"),
        "format_tokens.tl" => manifest_dir.join("selfhost").join("format_tokens.tl"),
        "text_buf_core.tl" => manifest_dir.join("selfhost").join("text_buf.tl"),
        "stdlib/string.tl" => manifest_dir.join("stdlib").join("string.tl"),
        "stdlib/test.tl" => manifest_dir.join("stdlib").join("test.tl"),
        "stdlib/io.tl" => manifest_dir.join("stdlib").join("io.tl"),
        _ => source_dir.join(dep),
    }
}

fn copy_case_deps(manifest_dir: &Path, source_dir: &Path, work_dir: &Path, deps: &[&str]) {
    for dep in deps {
        let dep_src = dep_source_path(manifest_dir, source_dir, dep);
        let dep_dst = work_dir.join(dep);
        if let Some(parent) = dep_dst.parent() {
            fs::create_dir_all(parent).expect("create dep work dir");
        }
        copy_tl_source(&dep_src, &dep_dst);
    }
}

fn copy_tl_source(source: &Path, dest: &Path) {
    let text = fs::read_to_string(source)
        .unwrap_or_else(|err| panic!("read TypeLisp source {}: {}", source.display(), err));
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    fs::write(dest, normalized)
        .unwrap_or_else(|err| panic!("write TypeLisp source {}: {}", dest.display(), err));
}
