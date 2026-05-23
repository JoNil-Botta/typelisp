//! Cross-platform proof that the self-hosted formatter layout engine compiles.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn tl_format_doc_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join("format_doc.tl");

    let work_dir = manifest_dir
        .join("target")
        .join("tl-format-doc-compile-test");
    fs::create_dir_all(&work_dir).expect("create format_doc compile test work dir");
    let asm_path = work_dir.join("format_doc.s");

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
        "format_doc.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated format_doc assembly");

    assert!(
        !asm.contains("# TODO"),
        "format_doc assembly still contains a # TODO marker:\n{}",
        asm,
    );

    for sym in [
        "_tl_doc_empty:",
        "_tl_doc_text:",
        "_tl_doc_append:",
        "_tl_doc_nest:",
        "_tl_doc_group:",
        "_tl_spaces:",
        "_tl_flat_width:",
        "_tl_fits_flat:",
        "_tl_render_doc_in:",
        "_tl_render_doc_width:",
        "_tl_render_doc:",
        "_tl_format_doc_self_test:",
        "tl_string_concat:",
        "tl_string_eq:",
        "tl_alloc:",
    ] {
        assert!(
            asm.contains(sym),
            "format_doc assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }

    for literal in [
        ".string \"alpha\"",
        ".string \"beta\"",
        ".string \"alpha beta\"",
        ".string \"alpha\\n  beta\"",
        ".string \"a\\nb\"",
    ] {
        assert!(
            asm.contains(literal),
            "format_doc assembly is missing expected literal {:?}:\n{}",
            literal,
            asm,
        );
    }
}
