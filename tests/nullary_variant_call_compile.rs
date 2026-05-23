//! Cross-platform proof that the nullary-variant call-form program
//! (`tests/integration/nullary_variant_call.tl`) compiles all the way to valid
//! x86_64 assembly.
//!
//! refs #41, GAP (D): the zero-arg call form `(Ctor)` constructs a NULLARY enum
//! variant — equivalent to bare `Ctor` and consistent with payload construction
//! `(RGB v)`. The program builds `(Red)`/`(Green)` via the call form, the payload
//! variant `(RGB 9)`, and calls the zero-arg FUNCTION `(bias)` (the
//! disambiguation witness: a function name still calls; only an enum-typed head
//! constructs).
//!
//! Like `calc_compile.rs` / `lexer_compile.rs`, this test only invokes the
//! `compile` subcommand, so it runs everywhere — including the Windows dev box —
//! and asserts on the emitted assembly text. The assemble+link+run check is
//! Linux-gated in `tests/integration.rs`.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn nullary_variant_call_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir
        .join("tests")
        .join("integration")
        .join("nullary_variant_call.tl");

    let work_dir = manifest_dir
        .join("target")
        .join("nullary-variant-call-compile-test");
    fs::create_dir_all(&work_dir).expect("create compile test work dir");
    let asm_path = work_dir.join("nullary_variant_call.s");

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
        "nullary_variant_call.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated assembly");

    // Everything lowered: no stubbed-out / unimplemented constructs.
    assert!(
        !asm.contains("# TODO"),
        "assembly still contains a # TODO marker:\n{}",
        asm,
    );

    // A real program entry point and the `code` / `bias` helpers were emitted
    // (TypeLisp prefixes user symbols with `_tl_`).
    for sym in ["_tl_code:", "_tl_bias:"] {
        assert!(
            asm.contains(sym),
            "assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // Disambiguation witness: the zero-arg FUNCTION `(bias)` is a real call (it is
    // bound as a function type, not an enum type), so a `call _tl_bias` is emitted.
    // The nullary-variant call forms `(Red)`/`(Green)` are NOT function calls —
    // they construct inline, so there is no `call _tl_Red` / `call _tl_Green`.
    assert!(
        asm.contains("call _tl_bias"),
        "expected the zero-arg function (bias) to be CALLED:\n{}",
        asm,
    );
    assert!(
        !asm.contains("call _tl_Red") && !asm.contains("call _tl_Green"),
        "nullary variant call forms must construct, not call a function:\n{}",
        asm,
    );
}
