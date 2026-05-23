//! Compile coverage for the real selfhost compiler AST parser (#335).
//!
//! `compiler_parse_core.tl` is the reusable Sexpr -> `compiler_ast_types.tl`
//! parser. `compiler_parse.tl` is a tiny smoke driver that parses a
//! representative TypeLisp source string and returns 42 only if the top-level
//! declaration structure matches the expected import/extern/enum/struct/def/fn
//! sequence.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn compile_selfhost_source(source_file: &str, work_name: &str, asm_file: &str) -> String {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join(source_file);

    let work_dir = manifest_dir.join("target").join(work_name);
    fs::create_dir_all(&work_dir).expect("create compiler parse compile test work dir");
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

    fs::read_to_string(&asm_path).expect("read generated compiler parse assembly")
}

#[test]
fn tl_compiler_parse_core_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_parse_core.tl",
        "tl-compiler-parse-core-compile-test",
        "compiler_parse_core.s",
    );

    assert!(
        !asm.contains("# TODO"),
        "compiler_parse_core assembly still contains a # TODO marker:\n{}",
        asm,
    );

    for sym in [
        "_tl_parse_compiler_source:",
        "_tl_parse_compiler_tokens:",
        "_tl_cp_parse_decl:",
        "_tl_cp_parse_define:",
        "_tl_cp_parse_extern:",
        "_tl_cp_parse_defenum:",
        "_tl_cp_parse_defstruct:",
        "_tl_cp_parse_import:",
        "_tl_cp_parse_type:",
        "_tl_cp_parse_expr:",
        "_tl_cp_parse_pattern:",
        "_tl_cp_parse_match:",
        "_tl_compiler_parse_smoke:",
    ] {
        assert!(
            asm.contains(sym),
            "compiler_parse_core assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }

    for msg in [
        "compiler-parse: malformed define",
        "compiler-parse: malformed extern",
        "compiler-parse: malformed defenum",
        "compiler-parse: malformed defstruct",
        "compiler-parse: malformed import",
        "compiler-parse: malformed binary expression",
        "compiler-parse: malformed match arm",
        "compiler-parse: expected declaration",
    ] {
        assert!(
            asm.contains(msg),
            "compiler_parse_core assembly is missing error message {:?}:\n{}",
            msg,
            asm,
        );
    }
}

#[test]
fn tl_compiler_parse_driver_tl_compiles_to_assembly() {
    let asm = compile_selfhost_source(
        "compiler_parse.tl",
        "tl-compiler-parse-driver-compile-test",
        "compiler_parse.s",
    );

    assert!(
        !asm.contains("# TODO"),
        "compiler_parse assembly still contains a # TODO marker:\n{}",
        asm,
    );
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "compiler_parse assembly must have exactly one main:\n{}",
        asm,
    );

    for literal in [
        "(import \\\"pkg:math/src/lib.tl\\\")",
        "[n : i64]",
        "[(Some v) v]",
    ] {
        assert!(
            asm.contains(literal),
            "compiler_parse assembly is missing representative source literal {:?}:\n{}",
            literal,
            asm,
        );
    }
    assert!(
        asm.contains("call _tl_compiler_parse_smoke"),
        "compiler_parse driver does not call the structural smoke:\n{}",
        asm,
    );
}
