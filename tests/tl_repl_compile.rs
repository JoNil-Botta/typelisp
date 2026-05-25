//! Cross-platform proof that the selfhost REPL command driver compiles (#591).

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let stdlib_root = manifest_dir.join("stdlib");
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create REPL compile test work dir");
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

    fs::read_to_string(&asm_path).expect("read generated REPL assembly")
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
fn repl_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source("repl.tl", "tl-repl-compile-test", "repl.s");

    assert_no_todo(&asm, "repl");
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "repl assembly must have exactly one main:\n{asm}",
    );

    // The REPL driver's own functions.
    for sym in [
        "_tl_repl_banner:",
        "_tl_repl_help_text:",
        "_tl_repl_prompt:",
        "_tl_repl_dot_command_question:",
        "_tl_repl_type_command:",
        "_tl_repl_type_render:",
        "_tl_repl_handle_type_command:",
        "_tl_repl_handle_input:",
        "_tl_repl_handle_line:",
        "_tl_repl_loop:",
    ] {
        assert_symbol(&asm, sym, "repl");
    }

    // The stdin/flush runtime the loop is built on (#594) must be emitted.
    for sym in [
        ".L_tl_read_stdin_line",
        ".L_tl_stdin_eof",
        ".L_tl_flush_stdout",
    ] {
        assert_symbol(&asm, sym, "repl");
    }
}
