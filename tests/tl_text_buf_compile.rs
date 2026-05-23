//! Cross-platform compile coverage for the self-hosted deterministic text
//! buffer utility (`selfhost/text_buf.tl`).

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn tl_text_buf_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join("text_buf.tl");
    let work_dir = manifest_dir.join("target").join("tl-text-buf-compile-test");
    fs::create_dir_all(&work_dir).expect("create text_buf compile test work dir");
    let asm_path = work_dir.join("text_buf.s");

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
        "text_buf.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated text_buf assembly");
    assert!(
        !asm.contains("# TODO"),
        "text_buf assembly still contains a # TODO marker:\n{}",
        asm,
    );

    for sym in [
        "_tl_text_buf_empty:",
        "_tl_text_buf_append:",
        "_tl_text_chunk_list_concat:",
        "_tl_text_buf_append_buffer:",
        "_tl_text_chunks_render_rev:",
        "_tl_text_buf_render:",
    ] {
        assert!(
            asm.contains(sym),
            "text_buf assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }
}

#[test]
fn tl_text_buf_driver_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let source_path = manifest_dir
        .join("tests")
        .join("integration")
        .join("text_buf.tl");
    let work_dir = manifest_dir
        .join("target")
        .join("tl-text-buf-driver-compile-test");
    fs::create_dir_all(&work_dir).expect("create text_buf driver compile test work dir");

    let entry_path = work_dir.join("text_buf.tl");
    fs::copy(&source_path, &entry_path).expect("copy text_buf integration driver");
    fs::copy(
        selfhost_dir.join("text_buf.tl"),
        work_dir.join("text_buf_core.tl"),
    )
    .expect("copy selfhost text_buf.tl to work dir");

    let asm_path = work_dir.join("text_buf_driver.s");
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
        "text_buf driver compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated text_buf driver assembly");
    assert!(
        !asm.contains("# TODO"),
        "text_buf driver assembly still contains a # TODO marker:\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_text_buf_render"),
        "text_buf driver assembly shows no render call:\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_text_buf_append_buffer"),
        "text_buf driver assembly shows no append-buffer call:\n{}",
        asm,
    );
    assert!(
        asm.contains("tl_string_concat:"),
        "text_buf driver assembly is missing string concatenation runtime:\n{}",
        asm,
    );
}
