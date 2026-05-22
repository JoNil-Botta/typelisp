#![cfg(target_os = "linux")]

use std::fs;
use std::path::PathBuf;
use std::process::Command;

struct Case {
    name: &'static str,
    exit_code: i32,
    stdout: &'static str,
}

#[test]
fn type_lisp_programs_compile_link_and_run() {
    let cases = [
        Case {
            name: "hello",
            exit_code: 42,
            stdout: "",
        },
        Case {
            name: "arithmetic",
            exit_code: 47,
            stdout: "",
        },
        Case {
            name: "factorial",
            exit_code: 120,
            stdout: "",
        },
        Case {
            name: "fibonacci",
            exit_code: 13,
            stdout: "",
        },
        Case {
            name: "control_flow",
            exit_code: 15,
            stdout: "",
        },
        Case {
            name: "functions",
            exit_code: 32,
            stdout: "",
        },
        Case {
            name: "print",
            exit_code: 0,
            stdout: "42\nfalse\n",
        },
        Case {
            name: "print_char",
            exit_code: 0,
            stdout: "A\n",
        },
        Case {
            name: "many_args",
            exit_code: 36,
            stdout: "",
        },
    ];

    for case in cases {
        run_case(&case);
    }
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
