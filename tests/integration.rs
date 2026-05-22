#![cfg(target_os = "linux")]

use std::fs;
use std::path::PathBuf;
use std::process::Command;

struct Case {
    name: &'static str,
    exit_code: i32,
    stdout: &'static str,
    /// Additional source files (relative to tests/integration/) that the entry
    /// program imports; copied into the work dir preserving their relative path
    /// so `(import ...)` resolves. Empty for single-file programs.
    deps: &'static [&'static str],
}

#[test]
fn type_lisp_programs_compile_link_and_run() {
    let cases = [
        Case {
            name: "hello",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "arithmetic",
            exit_code: 47,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "factorial",
            exit_code: 120,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "fibonacci",
            exit_code: 13,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "control_flow",
            exit_code: 15,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "functions",
            exit_code: 32,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "print",
            exit_code: 0,
            stdout: "42\nfalse\n",
            deps: &[],
        },
        Case {
            name: "print_char",
            exit_code: 0,
            stdout: "A\n",
            deps: &[],
        },
        Case {
            name: "unit_functions",
            exit_code: 7,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "unit_main",
            exit_code: 0,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "tl_alloc",
            exit_code: 0,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "many_args",
            exit_code: 36,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "narrow_div_mod",
            exit_code: 30,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "string_length",
            exit_code: 5,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "string_eq",
            exit_code: 0,
            stdout: "true\nfalse\nfalse\ntrue\n",
            deps: &[],
        },
        Case {
            name: "substring",
            exit_code: 33,
            stdout: "",
            deps: &[],
        },
        // Multi-file program (#44): entry imports a helper module and calls a
        // function defined there; exercises the module-graph loader end to end.
        Case {
            name: "modules_main",
            exit_code: 30,
            stdout: "",
            deps: &["modules_helper.tl"],
        },
        // Enum definition, constructor, and pattern matching end to end.
        Case {
            name: "enum_match",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        // Self-hosting (#27, phase 4): a tokenizer written in TypeLisp itself.
        // Lexes "foo + (12)" into 5 tokens: TIdent("foo") TPlus TLParen
        // TInt(12) TRParen. The first token is read back from `(Array Token)`
        // and its substring-sliced text is projected out of `(TIdent "foo")`.
        // `main` returns token count (5) + identifier text length (3) = 8.
        Case {
            name: "lexer",
            exit_code: 8,
            stdout: "",
            deps: &[],
        },
        // refs #27/#41: a String-payload enum variant constructed, returned
        // across a function boundary (heap-promoted), and its payload bound
        // back out in a `match` arm. `(TIdent "hello")` -> length 5.
        Case {
            name: "enum_string_payload",
            exit_code: 5,
            stdout: "",
            deps: &[],
        },
    ];

    for case in cases {
        run_case(&case);
    }
}

#[test]
fn type_lisp_programs_compile_link_and_run_explicit_build() {
    let cases = [
        Case {
            name: "hello",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "arithmetic",
            exit_code: 47,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "factorial",
            exit_code: 120,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "fibonacci",
            exit_code: 13,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "control_flow",
            exit_code: 15,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "functions",
            exit_code: 32,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "print",
            exit_code: 0,
            stdout: "42\nfalse\n",
            deps: &[],
        },
        Case {
            name: "print_char",
            exit_code: 0,
            stdout: "A\n",
            deps: &[],
        },
        Case {
            name: "unit_functions",
            exit_code: 7,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "unit_main",
            exit_code: 0,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "tl_alloc",
            exit_code: 0,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "many_args",
            exit_code: 36,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "narrow_div_mod",
            exit_code: 30,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "string_length",
            exit_code: 5,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "string_eq",
            exit_code: 0,
            stdout: "true\nfalse\nfalse\ntrue\n",
            deps: &[],
        },
        Case {
            name: "substring",
            exit_code: 33,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "modules_main",
            exit_code: 30,
            stdout: "",
            deps: &["modules_helper.tl"],
        },
        Case {
            name: "enum_match",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        // Self-hosting (#27, phase 4): the TypeLisp tokenizer, also exercised
        // through the explicit compile -> as -> ld -> run pipeline. Lexes
        // "foo + (12)" into 5 tokens and reads the first identifier token back
        // from `(Array Token)`; `main` returns 5 + 3 = 8.
        Case {
            name: "lexer",
            exit_code: 8,
            stdout: "",
            deps: &[],
        },
        // refs #27/#41: String-payload variant construct/return/match, also
        // through the explicit compile -> as -> ld -> run pipeline.
        Case {
            name: "enum_string_payload",
            exit_code: 5,
            stdout: "",
            deps: &[],
        },
    ];

    for case in cases {
        run_case_explicit_build(&case);
    }
}

fn run_case_explicit_build(case: &Case) {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir
        .join("tests")
        .join("integration")
        .join(format!("{}.tl", case.name));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests-explicit")
        .join(case.name);
    fs::create_dir_all(&work_dir).expect("create explicit build test work dir");
    let work_path = work_dir.join(format!("{}.tl", case.name));
    fs::copy(&source_path, &work_path).expect("copy TypeLisp program to work dir");

    // Copy any imported helper modules alongside the entry file.
    for dep in case.deps {
        let dep_src = manifest_dir.join("tests").join("integration").join(dep);
        let dep_dst = work_dir.join(dep);
        if let Some(parent) = dep_dst.parent() {
            fs::create_dir_all(parent).expect("create dep work dir");
        }
        fs::copy(&dep_src, &dep_dst).expect("copy imported module to work dir");
    }

    let asm_path = work_path.with_extension("s");
    let obj_path = work_path.with_extension("o");
    let bin_path = work_path.with_extension("");

    // Compile .tl → .s using the "compile" subcommand
    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("compile")
        .arg(&work_path)
        .output()
        .expect("run typelisp compile");

    let compile_stdout = String::from_utf8_lossy(&output.stdout);
    let compile_stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "{} compile step failed\nstdout:\n{}\nstderr:\n{}",
        case.name,
        compile_stdout,
        compile_stderr,
    );

    // Assemble .s → .o
    let status = Command::new("as")
        .arg(&asm_path)
        .arg("-o")
        .arg(&obj_path)
        .status()
        .expect("run assembler");
    assert!(status.success(), "{} assembly failed", case.name);

    // Link .o → binary
    let status = Command::new("ld")
        .arg(&obj_path)
        .arg("-o")
        .arg(&bin_path)
        .arg("-dynamic-linker")
        .arg("/lib64/ld-linux-x86-64.so.2")
        .arg("-lc")
        .status()
        .expect("run linker");
    assert!(status.success(), "{} linking failed", case.name);

    // Run binary
    let output = Command::new(&bin_path)
        .output()
        .expect("run compiled binary");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(case.exit_code),
        "{} exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        case.name,
        stdout,
        stderr,
    );
    assert_eq!(
        stdout, case.stdout,
        "{} stdout differed\nstderr:\n{}",
        case.name, stderr,
    );
}

fn run_case(case: &Case) {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir
        .join("tests")
        .join("integration")
        .join(format!("{}.tl", case.name));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join(case.name);
    fs::create_dir_all(&work_dir).expect("create integration test work dir");
    let work_path = work_dir.join(format!("{}.tl", case.name));
    fs::copy(&source_path, &work_path).expect("copy TypeLisp program to work dir");

    // Copy any imported helper modules alongside the entry file, preserving
    // their relative path so `(import "...")` resolves at load time.
    for dep in case.deps {
        let dep_src = manifest_dir.join("tests").join("integration").join(dep);
        let dep_dst = work_dir.join(dep);
        if let Some(parent) = dep_dst.parent() {
            fs::create_dir_all(parent).expect("create dep work dir");
        }
        fs::copy(&dep_src, &dep_dst).expect("copy imported module to work dir");
    }

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .output()
        .expect("run typelisp");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(case.exit_code),
        "{} exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        case.name,
        stdout,
        stderr
    );
    assert_eq!(
        stdout, case.stdout,
        "{} stdout differed\nstderr:\n{}",
        case.name, stderr
    );
}
