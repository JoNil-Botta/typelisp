//! Cross-platform proof that the M1 Sexpr -> compiler AST parser compiles.
//!
//! `selfhost/ast.tl` imports the TypeLisp reader, parses generic `Sexpr`
//! trees into the shared `BinOp` / `Expr` / `Item` AST enums, and scores both an
//! expression, a `define` form, a single-binding let, if, the comparison
//! operators, string literals, print forms, begin sequences, and set! parsing.
//! The Linux integration test executes the same witness; this test keeps
//! Windows coverage at compile time.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn tl_ast_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join("ast.tl");

    let work_dir = manifest_dir.join("target").join("tl-ast-compile-test");
    fs::create_dir_all(&work_dir).expect("create tl_ast compile test work dir");
    let asm_path = work_dir.join("tl_ast.s");

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
        "ast.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated tl_ast assembly");

    assert!(
        !asm.contains("# TODO"),
        "tl_ast assembly still contains a # TODO marker:\n{}",
        asm,
    );
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "tl_ast assembly must have exactly one main:\n{}",
        asm,
    );

    for sym in [
        "_tl_parse_expr:",
        "_tl_parse_binary:",
        "_tl_parse_let:",
        "_tl_parse_if:",
        "_tl_parse_while:",
        "_tl_parse_print:",
        "_tl_parse_set:",
        "_tl_parse_begin:",
        "_tl_parse_args:",
        "_tl_parse_params:",
        "_tl_parse_item:",
        "_tl_expr_score:",
        "_tl_item_score:",
        "_tl_read:",
        "_tl_read_form:",
        "_tl_lex:",
        "_tl_token_sym:",
    ] {
        assert!(
            asm.contains(sym),
            "tl_ast assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }

    for call in [
        "call _tl_parse_expr",
        "call _tl_parse_if",
        "call _tl_parse_while",
        "call _tl_parse_print",
        "call _tl_parse_set",
        "call _tl_parse_begin",
        "call _tl_parse_item",
        "call _tl_read",
        "call _tl_lex",
        "call tl_string_eq",
        "call .L_tl_abort",
    ] {
        assert!(
            asm.contains(call),
            "tl_ast assembly is missing expected call {}:\n{}",
            call,
            asm,
        );
    }

    for msg in [
        "ast: malformed expression",
        "ast: malformed let",
        "ast: malformed if",
        "ast: malformed while",
        "ast: malformed print",
        "ast: malformed set!",
        "ast: malformed begin",
        "ast: empty begin",
        "ast: malformed argument list",
        "ast: malformed parameter list",
        "ast: malformed define header",
        "ast: expected define",
    ] {
        assert!(
            asm.contains(msg),
            "tl_ast assembly is missing panic message {:?}:\n{}",
            msg,
            asm,
        );
    }

    assert!(
        asm.contains(".string \"(let ((x (* 2 3))) (+ x 1))\""),
        "tl_ast assembly is missing the let source-string datum:\n{}",
        asm,
    );
    assert!(
        asm.contains(".string \"(if (< 1 2) (= 3 3) 0)\""),
        "tl_ast assembly is missing the if source-string datum:\n{}",
        asm,
    );
    for datum in [
        ".string \"(<= 3 3)\"",
        ".string \"(> 5 2)\"",
        ".string \"(>= 5 5)\"",
        ".string \"(!= 7 8)\"",
    ] {
        assert!(
            asm.contains(datum),
            "tl_ast assembly is missing comparison source-string datum {:?}:\n{}",
            datum,
            asm,
        );
    }
    for datum in [".string \"\\\"hi\\\"\"", ".string \"(print \\\"ok\\\")\""] {
        assert!(
            asm.contains(datum),
            "tl_ast assembly is missing string/print source-string datum {:?}:\n{}",
            datum,
            asm,
        );
    }
}

#[test]
fn tl_compiler_ast_types_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join("compiler_ast_types.tl");

    let work_dir = manifest_dir
        .join("target")
        .join("tl-compiler-ast-types-compile-test");
    fs::create_dir_all(&work_dir).expect("create compiler_ast_types compile test work dir");
    let asm_path = work_dir.join("compiler_ast_types.s");

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
        "compiler_ast_types.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated compiler_ast_types assembly");

    assert!(
        !asm.contains("# TODO"),
        "compiler_ast_types assembly still contains a # TODO marker:\n{}",
        asm,
    );
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_ast_types assembly must have exactly one synthesized main:\n{}",
        asm,
    );

    for sym in [
        "_tl_ast_type_tag:",
        "_tl_ast_expr_tag:",
        "_tl_ast_expr_unspan:",
        "_tl_ast_decl_tag:",
        "_tl_compiler_ast_smoke:",
    ] {
        assert!(
            asm.contains(sym),
            "compiler_ast_types assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }

    for literal in [".string \"x\"", ".string \"main\""] {
        assert!(
            asm.contains(literal),
            "compiler_ast_types assembly is missing smoke literal {:?}:\n{}",
            literal,
            asm,
        );
    }
}
