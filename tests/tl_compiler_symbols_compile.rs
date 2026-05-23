//! Cross-platform proof that the selfhost compiler symbol-table slice compiles.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create compiler symbols compile test work dir");
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

    fs::read_to_string(&asm_path).expect("read generated compiler symbols assembly")
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
fn compiler_symbols_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_symbols.tl",
        "tl-compiler-symbols-compile-test",
        "compiler_symbols.s",
    );

    assert_no_todo(&asm, "compiler_symbols");

    for sym in [
        "_tl_compiler_symbol_make_handle:",
        "_tl_compiler_symbol_handle_kind:",
        "_tl_compiler_symbol_handle_index:",
        "_tl_compiler_registry_make_handle:",
        "_tl_compiler_registry_handle_owner_index:",
        "_tl_compiler_registry_handle_child_index:",
        "_tl_compiler_registries_lookup_variant:",
        "_tl_compiler_registries_lookup_struct_field:",
        "_tl_build_compiler_registries:",
        "_tl_build_compiler_registries_from_source:",
        "_tl_compiler_registries_variant_fields:",
        "_tl_compiler_registries_struct_field_type:",
        "_tl_compiler_symbols_lookup_value:",
        "_tl_compiler_symbols_lookup_type:",
        "_tl_build_compiler_symbols:",
        "_tl_build_compiler_symbols_from_source:",
        "_tl_compiler_symbols_self_test:",
        "_tl_parse_ast_source:",
        "_tl_sym_i64_bind:",
    ] {
        assert_symbol(&asm, sym, "compiler_symbols");
    }

    for message in [
        "symbols: duplicate value declaration ",
        "symbols: duplicate type declaration ",
        "symbols: duplicate enum variant ",
        "symbols: duplicate field ",
        "symbols: smoke score mismatch",
        "(defstruct Point (x i64) (y i64))",
        "(define (main [argc : i64] [name : String]) : i64",
    ] {
        assert_message(&asm, message, "compiler_symbols");
    }
}

#[test]
fn compiler_symbols_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_symbols_smoke.tl",
        "tl-compiler-symbols-smoke-compile-test",
        "compiler_symbols_smoke.s",
    );

    assert_no_todo(&asm, "compiler_symbols_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_symbols_smoke assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_compiler_symbols_self_test:",
        "_tl_build_compiler_symbols_from_source:",
        "_tl_build_compiler_registries_from_source:",
        "_tl_compiler_symbols_duplicate_value_ok_question:",
        "_tl_compiler_registries_duplicate_variant_ok_question:",
    ] {
        assert_symbol(&asm, sym, "compiler_symbols_smoke");
    }
}
