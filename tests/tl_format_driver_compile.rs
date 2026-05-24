//! Cross-platform proof that the self-hosted TypeLisp formatter driver
//! (`selfhost/format.tl`) compiles with its formatter-rule imports and wires
//! up the file/argument runtime it needs to run as a file-to-file tool.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);
    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create format driver compile test work dir");
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

    fs::read_to_string(&asm_path).expect("read generated format driver assembly")
}

#[test]
fn format_driver_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source("format.tl", "tl-format-driver-compile-test", "format.s");

    assert!(
        !asm.contains("# TODO"),
        "format driver assembly still contains a # TODO marker:\n{asm}",
    );
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "format driver assembly must have exactly one main:\n{asm}",
    );

    // The driver entry plus the formatter pipeline it calls through.
    for sym in [
        "_tl_format_file:",
        "_tl_format_rules_render_source:",
        "_tl_format_rules_source_doc:",
        "_tl_parse_format_source:",
        "_tl_render_doc:",
    ] {
        assert!(
            asm.contains(sym),
            "format driver assembly is missing expected symbol {sym}:\n{asm}",
        );
    }

    // The file-to-file runtime the driver depends on: argv access plus file IO.
    for marker in [
        ".L_tl_arg_count:",
        ".L_tl_arg:",
        ".L_tl_read_file:",
        ".L_tl_write_file:",
        "format: expected input and output paths",
    ] {
        assert!(
            asm.contains(marker),
            "format driver assembly is missing runtime marker {marker:?}:\n{asm}",
        );
    }
}
