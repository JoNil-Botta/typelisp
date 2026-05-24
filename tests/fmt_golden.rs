//! Golden-output and idempotence coverage for the self-hosted formatter,
//! driven through the supported `typelisp fmt` (in-place) entry point that runs
//! `selfhost/format.tl` (#522/#530).
//!
//! The existing `tests/cli.rs` fmt tests prove the CLI formats in place and
//! that `--check` flags changes, but they do not pin exact width-80 output for
//! representative source categories nor assert a dedicated double-format
//! idempotence property. This file fills that gap (re-scoped #328) using the
//! fixtures under `tests/format_golden/`.
//!
//! `typelisp fmt` compiles and runs the selfhost driver for the host platform,
//! so execution is covered on Linux and Windows while the file still compiles
//! on every platform.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

// Known-good formatter output at the default width (80 columns), mirroring the
// width-80 pairs asserted by `format-rules-self-test` in
// `selfhost/format_rules.tl` (and the `format_rules_integration` CI case), which
// is exactly what the driver renders via `format-rules-render-source-width src 80`.
const DECLS_EXPECTED: &str = "(import \"std.tl\")\n\n(extern print-string : (-> String unit))\n\n(defenum Maybe\n  (Some i64)\n  (None))\n\n(defstruct Point\n  (x i64)\n  (y i64))";
const FLOW_EXPECTED: &str = "(define (main [x : i64]) : i64\n  (begin\n    (let ([y : i64 1])\n      (if (< x y)\n        (while (< x 10)\n          (set! x (+ x 1)))\n        x))\n    (match (Some x)\n      [(Some v) v]\n      [None 0])))";
const COMMENTS_EXPECTED: &str = "(begin\n  ; keep\n  (print-string \"x\"))";
const CHAR_LITERAL_EXPECTED: &str = "(define (is-quote [c : char]) : bool\n  (= c #''))";
const NEGATIVE_INT_EXPECTED: &str = "(define (main) : i64\n  -128)";

#[test]
fn fmt_produces_golden_output_and_is_idempotent() {
    if cfg!(any(target_os = "linux", target_os = "windows")) {
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let golden_dir = manifest_dir.join("tests").join("format_golden");
        let work_dir = manifest_dir.join("target").join("fmt-golden-test");
        fs::create_dir_all(&work_dir).expect("create fmt golden work dir");

        let run = |args: &[&str]| -> std::process::Output {
            Command::new(env!("CARGO_BIN_EXE_typelisp"))
                .args(args)
                .output()
                .expect("run typelisp fmt")
        };

        let cases = [
            ("decls", DECLS_EXPECTED),
            ("flow", FLOW_EXPECTED),
            ("comments", COMMENTS_EXPECTED),
            ("char_literal", CHAR_LITERAL_EXPECTED),
            ("negative_int", NEGATIVE_INT_EXPECTED),
        ];

        for (name, expected) in cases {
            // Copy the committed fixture into the work dir so the in-place
            // formatter never rewrites the checked-in input.
            let fixture = golden_dir.join(format!("{name}.tl"));
            let source = fs::read_to_string(&fixture)
                .unwrap_or_else(|e| panic!("read fixture {name}.tl: {e}"));
            let work = work_dir.join(format!("{name}.tl"));
            fs::write(&work, &source).expect("seed work file");
            let work_arg = work.to_str().expect("work path is utf-8");

            // Golden: formatting the representative input yields exact width-80 output.
            let formatted = run(&["fmt", work_arg]);
            assert!(
                formatted.status.success(),
                "fmt '{name}' failed\nstderr:\n{}",
                String::from_utf8_lossy(&formatted.stderr),
            );
            assert_eq!(
                fs::read_to_string(&work).expect("read formatted work file"),
                expected,
                "fmt produced unexpected golden output for '{name}'",
            );

            // Idempotence (1): --check on already-formatted output exits 0, no diff.
            let check = run(&["fmt", "--check", work_arg]);
            assert!(
                check.status.success(),
                "fmt --check '{name}' reported a change on formatted output\nstderr:\n{}",
                String::from_utf8_lossy(&check.stderr),
            );

            // Idempotence (2): re-formatting already-formatted output changes nothing.
            let again = run(&["fmt", work_arg]);
            assert!(
                again.status.success(),
                "second fmt '{name}' failed\nstderr:\n{}",
                String::from_utf8_lossy(&again.stderr),
            );
            assert_eq!(
                fs::read_to_string(&work).expect("read re-formatted work file"),
                expected,
                "fmt is not idempotent for '{name}'",
            );
        }
    }
}
