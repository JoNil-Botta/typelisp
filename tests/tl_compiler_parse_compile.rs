//! Cross-platform proof that the selfhost parser for the real compiler AST
//! compiles and keeps its representative structural smoke source embedded.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create compiler parse compile test work dir");
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

    fs::read_to_string(&asm_path).expect("read generated compiler parse assembly")
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

fn assert_dispatch_env_call_shape(asm: &str, name: &str) {
    assert_eq!(
        asm.matches("call _tl_compiler_parse_dispatch_env").count(),
        1,
        "{name} should build the compiler parser dispatch env only in \
         parse-ast-program, not recursive parse helpers:\n{asm}",
    );
}

#[test]
fn compiler_parse_core_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_parse_core.tl",
        "tl-compiler-parse-core-compile-test",
        "compiler_parse_core.s",
    );

    assert_no_todo(&asm, "compiler_parse_core");

    for sym in [
        "_tl_compiler_parse_dispatch_env:",
        "_tl_compiler_parse_dispatch_tag:",
        "_tl_ast_source_span_from_source_span:",
        "_tl_ast_expr_wrap_span:",
        "_tl_ast_expr_inner_tag:",
        "_tl_parse_ast_type:",
        "_tl_parse_ast_expr:",
        "_tl_parse_ast_decl:",
        "_tl_parse_ast_program:",
        "_tl_parse_ast_source:",
        "_tl_parse_ast_match:",
        "_tl_parse_ast_foreach:",
        "_tl_parse_ast_cond:",
        "_tl_compiler_parse_smoke:",
        "_tl_compiler_parse_nested_expr_span_ok_question:",
        "_tl_compiler_parse_error_span_ok_question:",
        "_tl_read_form_spanned_result:",
        "_tl_lex_spanned_result:",
        "_tl_read_form:",
        "_tl_lex:",
        "_tl_sym_i64_lookup:",
        "_tl_ast_decl_tag:",
        "_tl_ast_expr_tag:",
    ] {
        assert_symbol(&asm, sym, "compiler_parse_core");
    }

    for message in [
        "parse: malformed define",
        "parse: malformed let",
        "parse: expected pattern",
        "parse: malformed foreach",
        "parse: cond requires final else arm",
        "parse: cond else arm must be final",
        "parse: compiler AST smoke score mismatch",
    ] {
        assert_message(&asm, message, "compiler_parse_core");
    }

    for datum in [
        "(import \\\"stdlib/test.tl\\\")",
        "(define (main [argc : i64] [name : String]) : i64",
        "(define (main) : i64 (+ 1 (* 2 3)))",
        "(define)",
        "(cond",
        "(match (Some x) [(Some v) v] [_ 0])",
    ] {
        assert!(
            asm.contains(datum),
            "compiler_parse_core assembly is missing smoke datum {datum:?}:\n{asm}",
        );
    }

    assert_dispatch_env_call_shape(&asm, "compiler_parse_core");
}

#[test]
fn compiler_parse_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_parse_smoke.tl",
        "tl-compiler-parse-smoke-compile-test",
        "compiler_parse_smoke.s",
    );

    assert_no_todo(&asm, "compiler_parse_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_parse_smoke assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_compiler_parse_smoke:",
        "_tl_compiler_parse_smoke_score:",
        "_tl_parse_ast_source:",
        "_tl_parse_ast_program:",
        "_tl_parse_ast_decl:",
    ] {
        assert_symbol(&asm, sym, "compiler_parse_smoke");
    }
}
