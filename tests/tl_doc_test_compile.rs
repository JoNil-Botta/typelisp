//! Cross-platform proof that the self-hosted TypeLisp doctest extractor compiles
//! and keeps its extraction policy fixtures embedded.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create doc test compile test work dir");
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

    fs::read_to_string(&asm_path).expect("read generated doc test assembly")
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

fn assert_literal(asm: &str, literal: &str, name: &str) {
    assert!(
        asm.contains(literal),
        "{name} assembly is missing expected literal {literal:?}:\n{asm}",
    );
}

#[test]
fn doc_test_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source("doc_test.tl", "tl-doc-test-compile-test", "doc_test.s");

    assert_no_todo(&asm, "doc_test");

    for sym in [
        "_tl_doc_test_extract_source:",
        "_tl_doc_test_extract_file:",
        "_tl_doc_test_parse_fence_info:",
        "_tl_doc_test_scan_doc_block:",
        "_tl_doc_test_supported_item_declaration_question:",
        "_tl_doc_test_smoke:",
    ] {
        assert_symbol(&asm, sym, "doc_test");
    }

    for literal in [
        ";;;; ```typelisp",
        ";;; ```tl expect-error",
        "unsupported TypeLisp doctest option",
        "empty TypeLisp doctest fence",
        "unterminated TypeLisp doctest fence",
        "doc-test: example metadata mismatch",
        "doc-test: ordinary comment example mismatch",
        "doc-test: malformed metadata mismatch",
    ] {
        assert_literal(&asm, literal, "doc_test");
    }
}

#[test]
fn doc_test_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "doc_test_smoke.tl",
        "tl-doc-test-smoke-compile-test",
        "doc_test_smoke.s",
    );

    assert_no_todo(&asm, "doc_test_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "doc_test_smoke assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_doc_test_smoke:",
        "_tl_doc_test_extract_source:",
        "_tl_doc_test_parse_fence_info:",
    ] {
        assert_symbol(&asm, sym, "doc_test_smoke");
    }
}
