//! Cross-platform proof that the self-hosted TypeLisp doc HTML renderer
//! compiles and keeps its smoke fixtures embedded.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create doc HTML compile test work dir");
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

    fs::read_to_string(&asm_path).expect("read generated doc HTML assembly")
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
fn doc_html_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source("doc_html.tl", "tl-doc-html-compile-test", "doc_html.s");

    assert_no_todo(&asm, "doc_html");

    for sym in [
        "_tl_doc_html_render_module_page:",
        "_tl_doc_html_render_module_graph:",
        "_tl_doc_html_render_source:",
        "_tl_doc_html_escape:",
        "_tl_doc_html_smoke:",
        "_tl_doc_render_anchor:",
        "_tl_doc_extract_source:",
        "_tl_format_lex:",
    ] {
        assert_symbol(&asm, sym, "doc_html");
    }

    for literal in [
        "<!doctype html>",
        "typelisp-docs.css",
        "tl-doc-module-nav",
        "&quot;",
        "tl-smoke-60-38-62-46tl",
        "doc-html: item anchor missing",
        "No documented declarations.",
    ] {
        assert_literal(&asm, literal, "doc_html");
    }
}

#[test]
fn doc_html_smoke_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "doc_html_smoke.tl",
        "tl-doc-html-smoke-compile-test",
        "doc_html_smoke.s",
    );

    assert_no_todo(&asm, "doc_html_smoke");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "doc_html_smoke assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_doc_html_smoke:",
        "_tl_doc_html_render_module_page:",
        "_tl_doc_html_render_module_graph:",
        "_tl_doc_render_anchor:",
        "_tl_doc_extract_source:",
        "_tl_format_lex:",
    ] {
        assert_symbol(&asm, sym, "doc_html_smoke");
    }
}
