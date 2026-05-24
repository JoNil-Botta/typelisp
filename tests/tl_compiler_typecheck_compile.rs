use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create compiler typecheck compile test work dir");
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

    fs::read_to_string(&asm_path).expect("read generated compiler typecheck assembly")
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
fn compiler_typecheck_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_typecheck.tl",
        "tl-compiler-typecheck-compile-test",
        "compiler_typecheck.s",
    );

    assert_no_todo(&asm, "compiler_typecheck");

    for sym in [
        "_tl_tc_type_eq:",
        "_tl_tc_expr:",
        "_tl_tc_check_decl:",
        "_tl_typecheck_compiler_program:",
        "_tl_typecheck_compiler_source:",
        "_tl_compiler_typecheck_self_test:",
        "_tl_build_compiler_symbols:",
        "_tl_parse_ast_source:",
    ] {
        assert_symbol(&asm, sym, "compiler_typecheck");
    }

    for message in [
        "typecheck: unbound name ",
        "typecheck: arity mismatch",
        "typecheck: argument type mismatch",
        "typecheck: if condition must be bool",
        "typecheck: if branches must match",
        "typecheck: assignment type mismatch",
        "typecheck: return type mismatch",
        "typecheck: tuple index out of bounds",
        "typecheck: array elements must have same type",
        "typecheck: string index must be integer",
        "typecheck: cast requires integer/char source and target",
        "typecheck: foreach body must be unit",
        "typecheck: lambda return type mismatch",
        "typecheck: smoke score mismatch",
        "(extern print-i64 : (-> i64 unit))",
        "[fixed : (Array i64 3) (array 1 2 3)]",
    ] {
        assert_message(&asm, message, "compiler_typecheck");
    }
}

#[test]
fn compiler_typecheck_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_typecheck_smoke.tl",
        "tl-compiler-typecheck-smoke-compile-test",
        "compiler_typecheck_smoke.s",
    );

    assert_no_todo(&asm, "compiler_typecheck_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_typecheck_smoke assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_compiler_typecheck_self_test:",
        "_tl_typecheck_compiler_source:",
        "_tl_compiler_typecheck_error_ok_question:",
    ] {
        assert_symbol(&asm, sym, "compiler_typecheck_smoke");
    }
}
