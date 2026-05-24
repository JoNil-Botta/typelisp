//! Cross-platform proof that the self-hosted TypeLisp documentation driver
//! compiles with its extractor and renderer imports.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create doc driver compile test work dir");
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

    fs::read_to_string(&asm_path).expect("read generated doc driver assembly")
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

#[test]
fn doc_driver_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source("doc.tl", "tl-doc-driver-compile-test", "doc.s");

    assert_no_todo(&asm, "doc");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "doc assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_doc_generate_file:",
        "_tl_doc_render_markdown:",
        "_tl_doc_extract_source:",
        "_tl_format_lex:",
    ] {
        assert_symbol(&asm, sym, "doc");
    }

    for marker in [
        ".L_tl_arg_count:",
        ".L_tl_arg:",
        ".L_tl_read_file:",
        ".L_tl_write_file:",
        "doc: expected input and output paths",
    ] {
        assert!(
            asm.contains(marker),
            "doc assembly is missing runtime marker {marker:?}:\n{asm}",
        );
    }
}
