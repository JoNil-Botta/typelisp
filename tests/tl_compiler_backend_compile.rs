//! Cross-platform proof that the selfhost compiler backend emitter slice compiles.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create compiler backend compile test work dir");
    let asm_path = work_dir.join(asm_file);

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("compile")
        .arg(&source_path)
        .arg("-o")
        .arg(&asm_path)
        .output()
        .expect("run typelisp compile");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "{} compile step failed\nstdout:\n{}\nstderr:\n{}",
        source_file,
        stdout,
        stderr,
    );

    fs::read_to_string(&asm_path).expect("read generated compiler backend assembly")
}

fn assert_no_todo(asm: &str, name: &str) {
    assert!(
        !asm.contains("# TODO"),
        "{name} assembly still contains a # TODO marker:\n{asm}",
    );
}

fn assert_symbol(asm: &str, sym: &str, name: &str) {
    assert!(
        asm.contains(sym),
        "{name} assembly is missing expected symbol {sym}:\n{asm}",
    );
}

fn assert_message(asm: &str, message: &str, name: &str) {
    assert!(
        asm.contains(message),
        "{name} assembly is missing message {message:?}:\n{asm}",
    );
}

#[test]
fn compiler_backend_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_backend.tl",
        "tl-compiler-backend-compile-test",
        "compiler_backend.s",
    );

    assert_no_todo(&asm, "compiler_backend");

    for sym in [
        "_tl_compiler_backend_emit_source:",
        "_tl_compiler_backend_emit_program:",
        "_tl_compiler_backend_emit_function:",
        "_tl_compiler_backend_emit_instr:",
        "_tl_compiler_backend_emit_phi_edge_copies:",
        "_tl_compiler_backend_emit_call_args:",
        "_tl_compiler_backend_emit_param_spills:",
        "_tl_compiler_backend_user_symbol:",
        "_tl_compiler_backend_call_symbol:",
        "_tl_compiler_backend_runtime_plan:",
        "_tl_compiler_backend_runtime_functions:",
        "_tl_compiler_backend_runtime_helper_program:",
        "_tl_compiler_backend_self_test:",
        "_tl_compiler_backend_deterministic_ok_question:",
        "_tl_compiler_backend_string_ok_question:",
        "_tl_compiler_backend_memory_op_ok_question:",
        "_tl_compiler_backend_emit_string_rodata:",
        "_tl_compiler_backend_emit_store_ptr:",
        "_tl_lower_compiler_source:",
        "_tl_text_buf_append:",
        "_tl_text_buf_render:",
    ] {
        assert_symbol(&asm, sym, "compiler_backend");
    }

    for message in [
        "backend: too many call args",
        "backend: too many params",
        "backend: unsupported global initializer",
        "backend: smoke output mismatch",
        ".L_tl_str_data_6869:",
        ".L_tl_str_6869:",
        "_tl_greeting:\\n    .quad .L_tl_str_6869\\n",
        ".globl _start\\n",
        "_start:\\n    call main\\n",
        "    call _tl_inc\\n",
        "    call tl_alloc\\n",
        "    call _tl_tl_alloc\\n",
        ".globl tl_string_concat\\n",
        "    jne .Lmain_while_body.1\\n",
        "    jmp .Lmain_while_header.0\\n",
        "    setl %al\\n",
        "    setg %al\\n",
    ] {
        assert_message(&asm, message, "compiler_backend");
    }
}

#[test]
fn compiler_backend_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_backend_smoke.tl",
        "tl-compiler-backend-smoke-compile-test",
        "compiler_backend_smoke.s",
    );

    assert_no_todo(&asm, "compiler_backend_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_backend_smoke assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_compiler_backend_self_test:",
        "_tl_compiler_backend_emit_source:",
        "_tl_compiler_backend_asm_ok_question:",
        "_tl_lower_compiler_source:",
    ] {
        assert_symbol(&asm, sym, "compiler_backend_smoke");
    }
}

#[test]
fn compiler_backend_runtime_fixture_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_backend_runtime_fixture.tl",
        "tl-compiler-backend-runtime-fixture-compile-test",
        "compiler_backend_runtime_fixture.s",
    );

    assert_no_todo(&asm, "compiler_backend_runtime_fixture");
    for sym in [
        "_tl_compiler_backend_runtime_helper_program:",
        "_tl_compiler_backend_runtime_helper_asm_ok_question:",
        "_tl_compiler_backend_emit_program:",
    ] {
        assert_symbol(&asm, sym, "compiler_backend_runtime_fixture");
    }
}

#[test]
fn compiler_driver_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_driver.tl",
        "tl-compiler-driver-compile-test",
        "compiler_driver.s",
    );

    assert_no_todo(&asm, "compiler_driver");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_driver assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_compiler_driver_compile_file:",
        "_tl_compiler_driver_emit_file:",
        "_tl_compiler_driver_load_file:",
        "_tl_compiler_driver_resolve_import:",
        "_tl_compiler_backend_emit_source:",
        "_tl_lower_compiler_source:",
        "_tl_parse_ast_source:",
        // The driver runs the optimizer between lowering and backend emission.
        "_tl_optimize_program:",
    ] {
        assert_symbol(&asm, sym, "compiler_driver");
    }

    for message in [
        "compiler-driver: expected input and output paths",
        "compiler-driver: cannot read import ",
        "lower: unsupported expression",
    ] {
        assert_message(&asm, message, "compiler_driver");
    }
}

#[test]
fn compiler_optimize_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_optimize.tl",
        "tl-compiler-optimize-compile-test",
        "compiler_optimize.s",
    );

    assert_no_todo(&asm, "compiler_optimize");
    for sym in [
        "_tl_optimize_program:",
        "_tl_optimize_function:",
        "_tl_opt_fold_instrs:",
        "_tl_opt_fold_binop:",
        "_tl_opt_const_lookup:",
        "_tl_compiler_optimize_self_test:",
    ] {
        assert_symbol(&asm, sym, "compiler_optimize");
    }
}

#[test]
fn compiler_optimize_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_optimize_smoke.tl",
        "tl-compiler-optimize-smoke-compile-test",
        "compiler_optimize_smoke.s",
    );

    assert_no_todo(&asm, "compiler_optimize_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_optimize_smoke assembly must have exactly one main:\n{asm}",
    );
    assert_symbol(
        &asm,
        "_tl_compiler_optimize_self_test:",
        "compiler_optimize_smoke",
    );
}

#[test]
fn compile_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source("compile.tl", "tl-compile-cli-compile-test", "compile_cli.s");

    assert_no_todo(&asm, "compile");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compile assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_compile_cli_config:",
        "_tl_compile_cli_parse_options:",
        "_tl_compile_cli_default_output:",
        "_tl_compiler_driver_compile_file:",
        "_tl_compiler_driver_load_file:",
    ] {
        assert_symbol(&asm, sym, "compile");
    }

    for message in [
        "compile: expected source path",
        "compile: -o requires a value",
        "compile: -o was provided more than once",
        "--emit-ir",
        " is not supported by the selfhost compile driver yet; use Rust typelisp compile",
        "compile: unknown flag ",
        "compile: unexpected argument ",
    ] {
        assert_message(&asm, message, "compile");
    }
}
