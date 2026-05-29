//! Cross-platform proof that the selfhost frontend inspection CLI driver compiles (#796).

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create frontend tools compile test work dir");
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

    fs::read_to_string(&asm_path).expect("read generated frontend tools assembly")
}

fn assert_symbol(asm: &str, sym: &str) {
    assert!(
        asm.contains(sym),
        "frontend_tools assembly is missing expected symbol {sym}:\n{asm}",
    );
}

#[test]
fn frontend_tools_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "frontend_tools.tl",
        "tl-frontend-tools-compile-test",
        "frontend_tools.s",
    );

    assert!(
        !asm.contains("# TODO"),
        "frontend_tools assembly still contains a # TODO marker:\n{asm}",
    );
    assert!(
        !asm.contains("_tl_print_char") && !asm.contains("tl_print_char"),
        "frontend_tools should preserve char token spelling without print-char runtime calls:\n{asm}",
    );
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "frontend_tools assembly must have exactly one main:\n{asm}",
    );

    for sym in [
        "_tl_front_tokenize_file:",
        "_tl_front_parse_file:",
        "_tl_front_scan_token:",
        "_tl_front_program_render:",
        "_tl_parse_ast_source_diagnostic:",
        "_tl_lex_spanned_result:",
    ] {
        assert_symbol(&asm, sym);
    }
}
