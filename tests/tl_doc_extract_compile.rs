//! Cross-platform proof that the self-hosted TypeLisp doc extractor compiles
//! and keeps its structural policy smoke source embedded.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create doc extract compile test work dir");
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

    fs::read_to_string(&asm_path).expect("read generated doc extract assembly")
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
fn doc_extract_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "doc_extract.tl",
        "tl-doc-extract-compile-test",
        "doc_extract.s",
    );

    assert_no_todo(&asm, "doc_extract");

    for sym in [
        "_tl_doc_extract_source:",
        "_tl_doc_extract_file:",
        "_tl_doc_decl_info:",
        "_tl_doc_scan_form_end:",
        "_tl_doc_extract_smoke:",
        "_tl_format_lex:",
        "_tl_format_token_tag:",
        "_tl_format_token_text:",
    ] {
        assert_symbol(&asm, sym, "doc_extract");
    }

    for message in [
        "doc-extract: module doc smoke mismatch",
        "doc-extract: item count smoke mismatch",
        "doc-extract: item doc smoke mismatch",
    ] {
        assert_message(&asm, message, "doc_extract");
    }

    for literal in [
        ";;;; Module title",
        ";;; answer doc",
        ";; ordinary comment ignored",
        "(define answer : i64 42)",
        "(define (main [argc : i64])",
        ";;; EOF unattached",
        "Module title\\nsecond module line\\nlater module",
    ] {
        assert!(
            asm.contains(literal),
            "doc_extract assembly is missing policy fixture literal {literal:?}:\n{asm}",
        );
    }
}

#[test]
fn doc_extract_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "doc_extract_smoke.tl",
        "tl-doc-extract-smoke-compile-test",
        "doc_extract_smoke.s",
    );

    assert_no_todo(&asm, "doc_extract_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "doc_extract_smoke assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_doc_extract_smoke:",
        "_tl_doc_extract_source:",
        "_tl_format_lex:",
    ] {
        assert_symbol(&asm, sym, "doc_extract_smoke");
    }
}
