//! Cross-platform proof that the selfhost LSP framing driver compiles.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let stdlib_root = manifest_dir.join("stdlib");
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create LSP frame compile test work dir");
    let asm_path = work_dir.join(asm_file);

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("compile")
        .arg(&source_path)
        .arg("--stdlib-root")
        .arg(&stdlib_root)
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

    fs::read_to_string(&asm_path).expect("read generated LSP frame assembly")
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
fn lsp_frame_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source("lsp_frame.tl", "tl-lsp-frame-compile-test", "lsp_frame.s");

    assert_no_todo(&asm, "lsp_frame");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "lsp_frame assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_lsp_frame_read_message:",
        "_tl_lsp_frame_write_body:",
        "_tl_lsp_frame_parse_content_length:",
        "_tl_lsp_frame_run:",
    ] {
        assert_symbol(&asm, sym, "lsp_frame");
    }

    for marker in [
        "Content-Length:",
        "lsp: missing Content-Length",
        "lsp: invalid Content-Length",
        "lsp: truncated payload",
        ".L_tl_read_stdin_line:",
        ".L_tl_read_stdin_bytes:",
        ".L_tl_stdin_eof:",
        ".L_tl_flush_stdout:",
    ] {
        assert!(
            asm.contains(marker),
            "lsp_frame assembly is missing marker {marker:?}:\n{asm}",
        );
    }
}
