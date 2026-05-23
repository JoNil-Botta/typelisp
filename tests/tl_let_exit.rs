//! Linux-gated end-to-end proof of self-hosted variables + single-binding `let`
//! (#163). The self-hosted pipeline in `tests/integration/tl_parse.tl`
//! (`lex -> read -> parse -> emit-program`) is driven on `let` source programs;
//! the printed `.s` is assembled (`as`) + linked (`ld`) + run, and its exit code
//! is asserted. Each case templates a different source string into the driver's
//! `main`, so one driver proves slot allocation, variable lookup, AND nesting:
//!
//!   (let ((x (* 2 3))) (+ x 1))            -> exit  7  (bind, use once)
//!   (let ((x 5)) (* x x))                  -> exit 25  (use the SAME slot twice)
//!   (let ((x 2)) (let ((y 3)) (* x y)))    -> exit  6  (nested, distinct slots)
//!
//! Windows can only compile-to-asm, so this whole module is Linux-only; the
//! cross-platform compile coverage lives in `tests/tl_parse_compile.rs` and
//! `tests/tl_emit_compile.rs`.
#![cfg(target_os = "linux")]

use std::fs;
use std::path::PathBuf;
use std::process::Command;

/// The exact source-string literal the stock `tl_parse.tl` driver runs its
/// pipeline on; each case rewrites this to its own `let` program.
const DEFAULT_SRC: &str = "(+ 1 (* 2 3))";

struct LetCase {
    /// A unique work-dir / file name segment.
    name: &'static str,
    /// The TypeLisp source the self-hosted pipeline compiles.
    src: &'static str,
    /// The exit code the produced binary must return.
    exit_code: i32,
}

#[test]
fn self_hosted_let_programs_assemble_link_and_run() {
    let cases = [
        LetCase {
            name: "let_bind_use",
            src: "(let ((x (* 2 3))) (+ x 1))",
            exit_code: 7,
        },
        LetCase {
            name: "let_use_twice",
            src: "(let ((x 5)) (* x x))",
            exit_code: 25,
        },
        LetCase {
            name: "let_nested",
            src: "(let ((x 2)) (let ((y 3)) (* x y)))",
            exit_code: 6,
        },
    ];

    for case in &cases {
        run_let_case(case);
    }
}

fn run_let_case(case: &LetCase) {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let integration_dir = manifest_dir.join("tests").join("integration");

    // Template the case's source string into a copy of the stock driver. The
    // driver runs `(emit-program (parse (read (lex "<SRC>"))))`, so swapping the
    // literal swaps the whole program the self-hosted pipeline compiles. We match
    // the literal INSIDE its `(lex "...")` call (not the bare string) because the
    // default source also appears in comments above `main`; targeting the call
    // form makes the substitution hit the one occurrence that drives the pipeline.
    let driver_src =
        fs::read_to_string(integration_dir.join("tl_parse.tl")).expect("read tl_parse.tl driver");
    let needle = format!("(lex \"{}\")", DEFAULT_SRC);
    assert_eq!(
        driver_src.matches(&needle).count(),
        1,
        "tl_parse.tl must embed exactly one `(lex \"{}\")` driver call",
        DEFAULT_SRC,
    );
    let driver_src = driver_src.replace(&needle, &format!("(lex \"{}\")", case.src));

    let work_dir = manifest_dir
        .join("target")
        .join("tl-let-exit")
        .join(case.name);
    fs::create_dir_all(&work_dir).expect("create let-exit test work dir");

    let work_path = work_dir.join("driver.tl");
    fs::write(&work_path, &driver_src).expect("write templated let driver");

    // Copy the imported front-end modules alongside so `(import ...)` resolves.
    for dep in ["tl_ast_types.tl", "tl_read.tl", "tl_lex.tl", "tl_token.tl"] {
        fs::copy(integration_dir.join(dep), work_dir.join(dep))
            .expect("copy imported front-end module to work dir");
    }

    // Run the driver: it PRINTS the full `.s` the self-hosted compiler produces
    // for `case.src`.
    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .output()
        .expect("run templated let driver");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}: let driver exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        case.name,
        stdout,
        stderr,
    );

    // Sanity: the produced program must store a let value into a slot, load a
    // variable back, and reserve the frame - the codegen this slice adds.
    assert!(
        stdout.contains("(%rbp)\n") && stdout.contains("sub $"),
        "{}: produced asm lacks let slot/frame codegen:\n{}",
        case.name,
        stdout,
    );
    assert!(
        !stdout.contains("# TODO"),
        "{}: produced asm still contains a # TODO marker:\n{}",
        case.name,
        stdout,
    );

    // Assemble + link + run the produced `.s`, asserting the exit code.
    let asm_path = work_dir.join("produced.s");
    let obj_path = work_dir.join("produced.o");
    let bin_path = work_dir.join("produced");
    fs::write(&asm_path, &output.stdout).expect("write produced assembly");

    let status = Command::new("as")
        .arg(&asm_path)
        .arg("-o")
        .arg(&obj_path)
        .status()
        .expect("run assembler on produced let program");
    assert!(
        status.success(),
        "{}: assembling produced asm failed",
        case.name
    );

    let status = Command::new("ld")
        .arg(&obj_path)
        .arg("-o")
        .arg(&bin_path)
        .status()
        .expect("run linker on produced let program");
    assert!(
        status.success(),
        "{}: linking produced asm failed",
        case.name
    );

    let output = Command::new(&bin_path)
        .output()
        .expect("run binary assembled from produced let program");
    let run_stdout = String::from_utf8_lossy(&output.stdout);
    let run_stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(case.exit_code),
        "{}: produced let program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        case.name,
        run_stdout,
        run_stderr,
    );
}
