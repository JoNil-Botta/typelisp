//! End-to-end golden + idempotence coverage for the self-hosted formatter
//! driver (`selfhost/format.tl`).
//!
//! The driver is exercised as a real file-to-file tool: it reads an input
//! `.tl` file, formats it with the self-hosted formatter rules, and writes the
//! result. We then assert the produced file contents match known-good output
//! (golden), and that re-running the driver over already-formatted output is a
//! no-op (idempotence).
//!
//! `typelisp run` compiles to native code and needs an assembler + linker, so
//! the execution is gated to Linux, matching the other run-based tests
//! (`integration.rs`, `spec_examples.rs`). The file still compiles everywhere.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

// Known-good formatter output rendered at the default width (80 columns). These
// mirror the width-80 pairs verified by `format-rules-self-test` in
// `selfhost/format_rules.tl`, so they stay in lockstep with the formatter.
const DECLS_EXPECTED: &str = "(import \"std.tl\")\n\n(extern print-string : (-> String unit))\n\n(defenum Maybe\n  (Some i64)\n  (None))\n\n(defstruct Point\n  (x i64)\n  (y i64))";
const FLOW_EXPECTED: &str = "(define (main [x : i64]) : i64\n  (begin\n    (let ([y : i64 1])\n      (if (< x y)\n        (while (< x 10)\n          (set! x (+ x 1)))\n        x))\n    (match (Some x)\n      [(Some v) v]\n      [None 0])))";
const COMMENTS_EXPECTED: &str = "(begin\n  ; keep\n  (print-string \"x\"))";

#[test]
fn format_driver_formats_golden_files_and_is_idempotent() {
    if cfg!(target_os = "linux") {
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let driver = manifest_dir.join("selfhost").join("format.tl");
        let golden_dir = manifest_dir.join("tests").join("format_golden");
        let work_dir = manifest_dir.join("target").join("format-driver-run-test");
        fs::create_dir_all(&work_dir).expect("create format driver run work dir");

        // Run the driver as `typelisp run selfhost/format.tl -- <in> <out>`.
        let run_driver = |input: &std::path::Path, output: &std::path::Path| {
            let out = Command::new(env!("CARGO_BIN_EXE_typelisp"))
                .arg("run")
                .arg(&driver)
                .arg("--")
                .arg(input)
                .arg(output)
                .output()
                .expect("spawn typelisp run for format driver");
            assert!(
                out.status.success(),
                "format driver run failed (input {input:?})\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr),
            );
        };

        let cases = [
            ("decls", "decls.tl", DECLS_EXPECTED),
            ("flow", "flow.tl", FLOW_EXPECTED),
            ("comments", "comments.tl", COMMENTS_EXPECTED),
        ];

        for (name, input_file, expected) in cases {
            // Golden: formatting the representative input yields the expected output.
            let input_path = golden_dir.join(input_file);
            let formatted_path = work_dir.join(format!("{name}.formatted.tl"));
            run_driver(&input_path, &formatted_path);
            let formatted =
                fs::read_to_string(&formatted_path).expect("read formatted driver output");
            assert_eq!(
                formatted, expected,
                "format driver produced unexpected output for '{name}'",
            );

            // Idempotence: re-formatting already-formatted output changes nothing.
            let fixed_input = work_dir.join(format!("{name}.fixed.tl"));
            fs::write(&fixed_input, expected).expect("write already-formatted fixture");
            let refixed_path = work_dir.join(format!("{name}.refixed.tl"));
            run_driver(&fixed_input, &refixed_path);
            let refixed = fs::read_to_string(&refixed_path).expect("read re-formatted output");
            assert_eq!(
                refixed, expected,
                "format driver is not idempotent for '{name}'",
            );
        }
    }
}
