//! Cross-platform proof that the TypeLisp self-hosting AST+parser slice compiles.
//!
//! `tests/integration/tl_ast.tl` defines the M1 compiler AST (`BinOp`, `Expr`,
//! `ExprList`, `StrList`, `Item`) and a parser from the generic `Sexpr` tree
//! into that typed AST. It imports `tl_read.tl` (which transitively pulls in
//! `tl_lex.tl` and `tl_token.tl`). This test only compiles the module so it
//! runs on Windows too; the Linux integration tests execute the witness programs
//! and assert their exit codes.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn tl_ast_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let integration_dir = manifest_dir.join("tests").join("integration");
    let source_path = integration_dir.join("tl_ast.tl");

    let work_dir = manifest_dir.join("target").join("tl-ast-compile-test");
    fs::create_dir_all(&work_dir).expect("create tl_ast compile test work dir");

    // The AST parser imports `tl_read.tl`, which imports `tl_lex.tl`, which
    // transitively imports `tl_token.tl`. The loader resolves imports relative
    // to the importing file, so every imported module must sit alongside the
    // entry file in the work dir.
    let entry_path = work_dir.join("tl_ast.tl");
    fs::copy(&source_path, &entry_path).expect("copy tl_ast.tl to work dir");
    for dep in ["tl_read.tl", "tl_lex.tl", "tl_token.tl"] {
        fs::copy(integration_dir.join(dep), work_dir.join(dep))
            .unwrap_or_else(|e| panic!("copy imported module {dep}: {e}"));
    }

    let asm_path = work_dir.join("tl_ast.s");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("compile")
        .arg(&entry_path)
        .arg("-o")
        .arg(&asm_path)
        .output()
        .expect("run typelisp compile");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "tl_ast.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated tl_ast assembly");

    assert!(
        !asm.contains("# TODO"),
        "tl_ast assembly still contains a # TODO marker:\n{}",
        asm,
    );

    // Shared AST symbols: the parser defines these and the emitter imports them.
    for sym in [
        "_tl_expect_sym:",
        "_tl_parse_expr:",
        "_tl_parse_expr_list:",
        "_tl_parse_str_list:",
        "_tl_parse_item:",
    ] {
        assert!(
            asm.contains(sym),
            "tl_ast assembly is missing expected parser symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // The imported reader and lexer symbols are present across the boundary.
    for sym in ["_tl_read_form:", "_tl_lex:", "_tl_token_tag:"] {
        assert!(
            asm.contains(sym),
            "tl_ast assembly is missing expected imported symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // The AST enum constructors are heap-allocated through tl_alloc.
    assert!(
        asm.contains("call tl_alloc"),
        "tl_ast assembly does not heap-allocate nodes via tl_alloc:\n{}",
        asm,
    );

    // Malformed input paths abort via panic -> the abort runtime.
    assert!(
        asm.contains("call .L_tl_abort"),
        "tl_ast assembly is missing the parser-error abort path (.L_tl_abort):\n{}",
        asm,
    );
}
