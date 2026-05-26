use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

fn fixture_dir(name: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time before unix epoch")
        .as_nanos();
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("target")
        .join(format!("cli-{name}-{}-{nonce}", std::process::id()));
    fs::create_dir_all(&dir).expect("create CLI fixture directory");
    dir
}

// The selfhost programs these tests spawn (the selfhost LSP frame tool and the
// selfhost compile driver) intermittently SEGFAULT on Windows CI with no useful
// output (#1204). `is_crash_exit` recognizes ONLY a transient crash exit so the
// run helpers can retry it without masking a genuine non-zero exit; mirrors
// `scripts/lib-retry.sh`'s `is_crash_code` (incl. the #1242 Windows NTSTATUS
// values, which `ExitStatus::code()` returns in their signed i32 form).
fn is_crash_exit(status: &std::process::ExitStatus) -> bool {
    match status.code() {
        // Windows NTSTATUS: 0xC0000005 access violation, 0xC000001D illegal instruction.
        Some(-1073741819) | Some(-1073741795) => true,
        // bash/MSYS 128+signal form, if it surfaces that way.
        Some(132) | Some(134) | Some(139) => true,
        _ => {
            #[cfg(unix)]
            {
                use std::os::unix::process::ExitStatusExt;
                // SIGILL=4, SIGABRT=6, SIGSEGV=11.
                matches!(status.signal(), Some(4) | Some(6) | Some(11))
            }
            #[cfg(not(unix))]
            {
                false
            }
        }
    }
}

// Run a subprocess closure, retrying ONLY a transient #1204 crash exit. Attempts
// default to 3, overridable via $CLI_TEST_ATTEMPTS.
fn run_with_crash_retry<F: FnMut() -> Output>(mut run: F) -> Output {
    let attempts: u32 = std::env::var("CLI_TEST_ATTEMPTS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(3);
    let mut out = run();
    let mut attempt = 1;
    while attempt < attempts && is_crash_exit(&out.status) {
        eprintln!(
            "  retry ({attempt}/{attempts}): crash exit {:?} — likely transient (#1204)",
            out.status.code()
        );
        out = run();
        attempt += 1;
    }
    out
}

// Run the selfhost compile/test driver binary with `args`, retrying transient
// #1204 crashes via `run_with_crash_retry`. Covers the inline driver-run sites
// that #1250 deferred (#1248). Failure-asserting callers are safe: a normal
// non-zero exit is not a crash code, so it returns immediately. Linux-only,
// matching the `#[cfg(target_os = "linux")]` selfhost-driver tests that call it.
#[cfg(target_os = "linux")]
fn driver_output(driver_bin: &std::path::Path, args: &[&str]) -> Output {
    run_with_crash_retry(|| {
        Command::new(driver_bin)
            .args(args)
            .output()
            .expect("run selfhost compile driver")
    })
}

fn typelisp(args: &[&str]) -> Output {
    run_with_crash_retry(|| {
        Command::new(env!("CARGO_BIN_EXE_typelisp"))
            .args(args)
            .output()
            .expect("run typelisp CLI")
    })
}

fn typelisp_with_stdin(args: &[&str], stdin: &str) -> Output {
    run_with_crash_retry(|| {
        let mut child = Command::new(env!("CARGO_BIN_EXE_typelisp"))
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn typelisp CLI");

        child
            .stdin
            .as_mut()
            .expect("stdin is piped")
            .write_all(stdin.as_bytes())
            .expect("write CLI stdin");

        child.wait_with_output().expect("wait for typelisp CLI")
    })
}

fn typelisp_with_path(args: &[&str], path: &std::path::Path) -> Output {
    run_with_crash_retry(|| {
        Command::new(env!("CARGO_BIN_EXE_typelisp"))
            .args(args)
            .env("PATH", path)
            .output()
            .expect("run typelisp CLI")
    })
}

fn lsp_frame(payload: &str) -> String {
    format!("Content-Length: {}\r\n\r\n{}", payload.len(), payload)
}

fn lsp_messages(output: &Output) -> Vec<String> {
    let mut messages = Vec::new();
    let bytes = &output.stdout;
    let mut offset = 0;
    while offset < bytes.len() {
        let header_end = find_bytes(&bytes[offset..], b"\r\n\r\n")
            .map(|idx| offset + idx)
            .expect("LSP output frame has header terminator");
        let header = std::str::from_utf8(&bytes[offset..header_end]).expect("header is utf-8");
        let len = header
            .lines()
            .find_map(|line| line.strip_prefix("Content-Length:"))
            .expect("LSP output has Content-Length")
            .trim()
            .parse::<usize>()
            .expect("Content-Length is numeric");
        let body_start = header_end + 4;
        let body_end = body_start + len;
        assert!(
            body_end <= bytes.len(),
            "LSP frame body exceeds output length"
        );
        messages.push(String::from_utf8(bytes[body_start..body_end].to_vec()).expect("body utf-8"));
        offset = body_end;
    }
    messages
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn json_string(value: &str) -> String {
    let mut out = String::from("\"");
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if ch.is_control() => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out.push('"');
    out
}

fn file_uri(path: &std::path::Path) -> String {
    let path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().expect("current dir").join(path)
    };
    let text = path.to_string_lossy().replace('\\', "/");
    if cfg!(windows) {
        format!("file:///{}", percent_encode_path(&text))
    } else if text.starts_with('/') {
        format!("file://{}", percent_encode_path(&text))
    } else {
        format!("file:///{}", percent_encode_path(&text))
    }
}

fn percent_encode_path(value: &str) -> String {
    let mut out = String::new();
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' | b':' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{:02X}", byte)),
        }
    }
    out
}

fn lsp_initialize(id: i64) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","id":{},"method":"initialize","params":{{"capabilities":{{}}}}}}"#,
        id
    )
}

fn lsp_shutdown(id: i64) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","id":{},"method":"shutdown","params":null}}"#,
        id
    )
}

fn lsp_did_open(uri: &str, text: &str) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":{},"languageId":"typelisp","version":1,"text":{}}}}}}}"#,
        json_string(uri),
        json_string(text)
    )
}

fn lsp_did_change(uri: &str, text: &str) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","method":"textDocument/didChange","params":{{"textDocument":{{"uri":{},"version":2}},"contentChanges":[{{"text":{}}}]}}}}"#,
        json_string(uri),
        json_string(text)
    )
}

fn lsp_did_close(uri: &str) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","method":"textDocument/didClose","params":{{"textDocument":{{"uri":{}}}}}}}"#,
        json_string(uri)
    )
}

fn run_lsp(messages: &[String]) -> Output {
    let input = messages
        .iter()
        .map(|message| lsp_frame(message))
        .collect::<String>();
    typelisp_with_stdin(&["lsp"], &input)
}

#[cfg(target_os = "linux")]
fn run_selfhost_lsp_frame(work_name: &str, stdin: &str) -> Output {
    let work_dir = fixture_dir(work_name);
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_src = manifest_dir.join("selfhost");
    let selfhost_work = work_dir.join("selfhost");
    fs::create_dir_all(&selfhost_work).expect("create staged selfhost LSP source dir");
    for entry in fs::read_dir(&selfhost_src).expect("read selfhost source dir") {
        let entry = entry.expect("read selfhost source entry");
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) == Some("tl") {
            fs::copy(
                &path,
                selfhost_work.join(path.file_name().expect("selfhost source has file name")),
            )
            .expect("copy staged selfhost source");
        }
    }
    let source = selfhost_work.join("lsp_frame.tl");
    let stdlib_root = manifest_dir.join("stdlib");
    let source_arg = source.to_str().expect("source path is utf-8");
    let stdlib_arg = stdlib_root.to_str().expect("stdlib path is utf-8");
    let mut args = vec!["run", source_arg, "--stdlib-root", stdlib_arg];
    if cfg!(target_os = "windows") {
        args.push("--target");
        args.push("windows-x86_64");
    }
    typelisp_with_stdin(&args, stdin)
}

#[cfg(target_os = "linux")]
fn selfhost_lsp_error_body(message: &str) -> String {
    format!(
        r#"{{"jsonrpc":"2.0","id":null,"error":{{"code":-32700,"message":"{}"}}}}"#,
        message
    )
}

fn write_main_source(dir: &std::path::Path) -> PathBuf {
    let source = dir.join("main.tl");
    fs::write(&source, "(define (main) : i64 42)\n").expect("write source");
    source
}

fn assert_doctest_temp_cleaned(source: &std::path::Path) {
    let temp_parent = source
        .parent()
        .expect("source has parent")
        .join(".typelisp-doctest");
    assert!(
        !temp_parent.exists(),
        "doctest temp directory was not cleaned: {}",
        temp_parent.display()
    );
}

#[test]
fn repl_is_listed_in_usage() {
    let output = typelisp(&["--help"]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert!(stderr(&output).contains("typelisp repl"));
}

#[test]
fn lsp_is_listed_in_usage() {
    let output = typelisp(&["--help"]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert!(stderr(&output).contains("typelisp lsp"));
}

#[test]
fn fmt_is_listed_in_usage() {
    let output = typelisp(&["--help"]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert!(stderr(&output).contains("typelisp fmt"));
}

#[test]
fn lsp_initialize_shutdown_exit_over_stdio() {
    let output = run_lsp(&[
        lsp_initialize(1),
        r#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#.to_string(),
        lsp_shutdown(2),
        r#"{"jsonrpc":"2.0","method":"exit"}"#.to_string(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    assert_eq!(messages.len(), 2, "messages: {messages:#?}");
    assert!(messages[0].contains(r#""id":1"#), "{}", messages[0]);
    assert!(
        messages[0].contains(r#""textDocumentSync":{"openClose":true,"change":1}"#),
        "{}",
        messages[0]
    );
    assert!(
        messages[1].contains(r#""id":2,"result":null"#),
        "{}",
        messages[1]
    );
}

#[test]
fn lsp_publishes_parse_and_type_diagnostics() {
    let dir = fixture_dir("lsp-diagnostics");
    let parse_uri = file_uri(&dir.join("parse_error.tl"));
    let type_uri = file_uri(&dir.join("type_error.tl"));
    let output = run_lsp(&[
        lsp_initialize(1),
        lsp_did_open(&parse_uri, "(define (main) : i64\n"),
        lsp_did_open(&type_uri, "(define (main) : i64 true)\n"),
        lsp_shutdown(2),
        r#"{"jsonrpc":"2.0","method":"exit"}"#.to_string(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    let parse_diag = messages
        .iter()
        .find(|message| message.contains(&parse_uri) && message.contains(r#""code":"E0100""#))
        .expect("missing parse diagnostic");
    assert!(
        parse_diag.contains("unexpected token"),
        "parse diagnostic: {parse_diag}"
    );
    let type_diag = messages
        .iter()
        .find(|message| message.contains(&type_uri) && message.contains(r#""code":"E0200""#))
        .expect("missing type diagnostic");
    assert!(
        type_diag.contains(r#""range":{"start":{"line":0,"character":"#)
            || type_diag.contains(r#""range":{"start":{"line":0,"character":0}"#),
        "type diagnostic range should be zero-based: {type_diag}"
    );
    assert!(
        type_diag.contains("expected i64"),
        "type diagnostic: {type_diag}"
    );
}

#[test]
fn lsp_clears_diagnostics_after_clean_change_and_close() {
    let dir = fixture_dir("lsp-clear");
    let uri = file_uri(&dir.join("main.tl"));
    let output = run_lsp(&[
        lsp_initialize(1),
        lsp_did_open(&uri, "(define (main) : i64 true)\n"),
        lsp_did_change(&uri, "(define (main) : i64 0)\n"),
        lsp_did_close(&uri),
        lsp_shutdown(2),
        r#"{"jsonrpc":"2.0","method":"exit"}"#.to_string(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    assert!(
        messages
            .iter()
            .any(|message| message.contains(&uri) && message.contains(r#""code":"E0200""#)),
        "messages: {messages:#?}"
    );
    let clears = messages
        .iter()
        .filter(|message| message.contains(&uri) && message.contains(r#""diagnostics":[]"#))
        .count();
    assert_eq!(clears, 2, "messages: {messages:#?}");
}

#[test]
fn lsp_checks_imports_relative_to_open_document() {
    let dir = fixture_dir("lsp-imports");
    fs::write(dir.join("lib.tl"), "(define imported : i64 41)\n").expect("write imported module");
    let uri = file_uri(&dir.join("main.tl"));
    let output = run_lsp(&[
        lsp_initialize(1),
        lsp_did_open(
            &uri,
            "(import \"lib.tl\")\n(define (main) : i64 imported)\n",
        ),
        lsp_shutdown(2),
        r#"{"jsonrpc":"2.0","method":"exit"}"#.to_string(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    assert!(
        messages
            .iter()
            .any(|message| message.contains(&uri) && message.contains(r#""diagnostics":[]"#)),
        "messages: {messages:#?}"
    );
}

#[test]
fn lsp_clears_stale_import_diagnostics_after_root_change() {
    let dir = fixture_dir("lsp-import-clear-change");
    let lib_path = dir.join("lib.tl");
    fs::write(&lib_path, "(define imported : i64 true)\n").expect("write imported module");
    let uri = file_uri(&dir.join("main.tl"));
    let lib_uri = file_uri(&lib_path);
    let output = run_lsp(&[
        lsp_initialize(1),
        lsp_did_open(&uri, "(import \"lib.tl\")\n(define (main) : i64 0)\n"),
        lsp_did_change(&uri, "(define (main) : i64 0)\n"),
        lsp_shutdown(2),
        r#"{"jsonrpc":"2.0","method":"exit"}"#.to_string(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    assert!(
        messages
            .iter()
            .any(|message| message.contains(&lib_uri) && message.contains(r#""code":"E0200""#)),
        "messages: {messages:#?}"
    );
    let import_clears = messages
        .iter()
        .filter(|message| message.contains(&lib_uri) && message.contains(r#""diagnostics":[]"#))
        .count();
    assert_eq!(import_clears, 1, "messages: {messages:#?}");
}

#[test]
fn lsp_clears_import_diagnostics_on_root_close() {
    let dir = fixture_dir("lsp-import-clear-close");
    let lib_path = dir.join("lib.tl");
    fs::write(&lib_path, "(define imported : i64 true)\n").expect("write imported module");
    let uri = file_uri(&dir.join("main.tl"));
    let lib_uri = file_uri(&lib_path);
    let output = run_lsp(&[
        lsp_initialize(1),
        lsp_did_open(&uri, "(import \"lib.tl\")\n(define (main) : i64 0)\n"),
        lsp_did_close(&uri),
        lsp_shutdown(2),
        r#"{"jsonrpc":"2.0","method":"exit"}"#.to_string(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    assert!(
        messages
            .iter()
            .any(|message| message.contains(&lib_uri) && message.contains(r#""code":"E0200""#)),
        "messages: {messages:#?}"
    );
    let import_clears = messages
        .iter()
        .filter(|message| message.contains(&lib_uri) && message.contains(r#""diagnostics":[]"#))
        .count();
    assert_eq!(import_clears, 1, "messages: {messages:#?}");
}

#[test]
fn lsp_keeps_shared_import_diagnostics_after_one_root_change() {
    let dir = fixture_dir("lsp-import-clear-shared");
    let lib_path = dir.join("lib.tl");
    fs::write(&lib_path, "(define imported : i64 true)\n").expect("write imported module");
    let root_a_uri = file_uri(&dir.join("main_a.tl"));
    let root_b_uri = file_uri(&dir.join("main_b.tl"));
    let lib_uri = file_uri(&lib_path);
    let output = run_lsp(&[
        lsp_initialize(1),
        lsp_did_open(
            &root_a_uri,
            "(import \"lib.tl\")\n(define (main) : i64 0)\n",
        ),
        lsp_did_open(
            &root_b_uri,
            "(import \"lib.tl\")\n(define (main) : i64 0)\n",
        ),
        lsp_did_change(&root_a_uri, "(define (main) : i64 0)\n"),
        lsp_shutdown(2),
        r#"{"jsonrpc":"2.0","method":"exit"}"#.to_string(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    let import_diagnostics = messages
        .iter()
        .filter(|message| message.contains(&lib_uri) && message.contains(r#""code":"E0200""#))
        .count();
    assert_eq!(import_diagnostics, 2, "messages: {messages:#?}");
    let import_clears = messages
        .iter()
        .filter(|message| message.contains(&lib_uri) && message.contains(r#""diagnostics":[]"#))
        .count();
    assert_eq!(import_clears, 0, "messages: {messages:#?}");
}

#[cfg(target_os = "linux")]
#[test]
fn selfhost_lsp_frame_reads_one_request() {
    let request = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#;
    let output = run_selfhost_lsp_frame("selfhost-lsp-frame-one", &lsp_frame(request));

    assert_eq!(
        output.status.code(),
        Some(0),
        "selfhost LSP frame exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    assert_eq!(messages.len(), 1, "messages: {messages:#?}");
    assert!(messages[0].contains(r#""id":1"#), "{}", messages[0]);
    assert!(
        messages[0].contains(r#""textDocumentSync":{"openClose":true,"change":1}"#),
        "{}",
        messages[0]
    );
}

#[cfg(target_os = "linux")]
#[test]
fn selfhost_lsp_frame_reads_multiple_requests() {
    let first = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#;
    let second = r#"{"jsonrpc":"2.0","id":2,"method":"shutdown"}"#;
    let input = format!("{}{}", lsp_frame(first), lsp_frame(second));
    let output = run_selfhost_lsp_frame("selfhost-lsp-frame-multiple", &input);

    assert_eq!(
        output.status.code(),
        Some(0),
        "selfhost LSP frame exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    assert_eq!(messages.len(), 2, "messages: {messages:#?}");
    assert!(messages[0].contains(r#""id":1"#), "{}", messages[0]);
    assert!(
        messages[0].contains(r#""textDocumentSync":{"openClose":true,"change":1}"#),
        "{}",
        messages[0]
    );
    assert!(
        messages[1].contains(r#""id":2,"result":null"#),
        "{}",
        messages[1]
    );
}

#[cfg(target_os = "linux")]
#[test]
fn selfhost_lsp_frame_reports_unknown_request_method() {
    let request = r#"{"jsonrpc":"2.0","id":9,"method":"workspace/unknown","params":{}}"#;
    let output = run_selfhost_lsp_frame("selfhost-lsp-unknown-method", &lsp_frame(request));

    assert_eq!(
        output.status.code(),
        Some(0),
        "selfhost LSP frame exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    assert_eq!(messages.len(), 1, "messages: {messages:#?}");
    assert!(messages[0].contains(r#""id":9"#), "{}", messages[0]);
    assert!(messages[0].contains(r#""code":-32601"#), "{}", messages[0]);
    assert!(
        messages[0].contains(r#""message":"Method not found""#),
        "{}",
        messages[0]
    );
}

#[cfg(target_os = "linux")]
#[test]
fn selfhost_lsp_frame_tracks_document_changes_and_diagnostics() {
    let dir = fixture_dir("selfhost-lsp-doc-diagnostics");
    let uri = file_uri(&dir.join("main.tl"));
    let input = format!(
        "{}{}{}{}",
        lsp_frame(&lsp_initialize(1)),
        lsp_frame(&lsp_did_open(&uri, "(define (main) : i64 true)\n")),
        lsp_frame(&lsp_did_change(&uri, "(define (main) : i64 0)\n")),
        lsp_frame(&lsp_did_close(&uri))
    );
    let output = run_selfhost_lsp_frame("selfhost-lsp-doc-diagnostics", &input);

    assert_eq!(
        output.status.code(),
        Some(0),
        "selfhost LSP frame exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert_eq!(stderr(&output), "");
    let messages = lsp_messages(&output);
    assert!(
        messages.iter().any(|message| {
            message.contains(&uri)
                && message.contains(r#""code":"E0200""#)
                && message.contains("typecheck: return type mismatch")
        }),
        "messages: {messages:#?}"
    );
    let clears = messages
        .iter()
        .filter(|message| message.contains(&uri) && message.contains(r#""diagnostics":[]"#))
        .count();
    assert_eq!(clears, 2, "messages: {messages:#?}");
}

#[cfg(target_os = "linux")]
#[test]
fn selfhost_lsp_frame_eof_before_header_exits_cleanly() {
    let output = run_selfhost_lsp_frame("selfhost-lsp-frame-eof", "");

    assert_eq!(
        output.status.code(),
        Some(0),
        "selfhost LSP frame exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert_eq!(stdout(&output), "");
    assert_eq!(stderr(&output), "");
}

#[cfg(target_os = "linux")]
#[test]
fn selfhost_lsp_frame_reports_missing_content_length() {
    let output = run_selfhost_lsp_frame("selfhost-lsp-frame-missing-length", "X-Test: 1\r\n\r\n");

    assert_eq!(
        output.status.code(),
        Some(1),
        "selfhost LSP frame exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert_eq!(stderr(&output), "lsp: missing Content-Length");
    assert_eq!(
        lsp_messages(&output),
        vec![selfhost_lsp_error_body("lsp: missing Content-Length")]
    );
}

#[cfg(target_os = "linux")]
#[test]
fn selfhost_lsp_frame_reports_invalid_content_length() {
    let output = run_selfhost_lsp_frame(
        "selfhost-lsp-frame-invalid-length",
        "Content-Length: nope\r\n\r\n",
    );

    assert_eq!(
        output.status.code(),
        Some(1),
        "selfhost LSP frame exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert_eq!(stderr(&output), "lsp: invalid Content-Length");
    assert_eq!(
        lsp_messages(&output),
        vec![selfhost_lsp_error_body("lsp: invalid Content-Length")]
    );
}

#[cfg(target_os = "linux")]
#[test]
fn selfhost_lsp_frame_reports_truncated_payload() {
    let output = run_selfhost_lsp_frame(
        "selfhost-lsp-frame-truncated-payload",
        "Content-Length: 10\r\n\r\nabc",
    );

    assert_eq!(
        output.status.code(),
        Some(1),
        "selfhost LSP frame exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert_eq!(stderr(&output), "lsp: truncated payload");
    assert_eq!(
        lsp_messages(&output),
        vec![selfhost_lsp_error_body("lsp: truncated payload")]
    );
}

#[test]
fn repl_help_and_exit_from_piped_stdin() {
    let output = typelisp_with_stdin(&["repl"], ".help\n.exit\n");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let stdout = stdout(&output);
    assert!(
        stdout.contains("TypeLisp REPL commands:"),
        "stdout:\n{}",
        stdout
    );
    assert!(stdout.contains(".help"), "stdout:\n{}", stdout);
    assert!(stdout.contains(".type"), "stdout:\n{}", stdout);
    assert!(stdout.contains(".exit"), "stdout:\n{}", stdout);
}

#[test]
fn repl_eof_exits_cleanly() {
    let output = typelisp_with_stdin(&["repl"], "");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "");
    assert_eq!(stderr(&output), "");
}

#[test]
fn repl_unknown_dot_command_reports_and_continues() {
    let output = typelisp_with_stdin(&["repl"], ".wat\n.help\n.exit\n");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert!(stdout(&output).contains("TypeLisp REPL commands:"));
    assert!(
        stderr(&output).contains("Unknown REPL command: .wat"),
        "stderr:\n{}",
        stderr(&output)
    );
}

#[test]
fn repl_accumulates_multiline_declaration_input() {
    let output = typelisp_with_stdin(
        &["repl"],
        "(define answer : i64\n  42)\n.type answer\n.exit\n",
    );

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "i64\n");
    assert_eq!(stderr(&output), "");
}

// Compiling and running a scratch program needs a native toolchain, so the
// expression-evaluation REPL tests are gated to Linux like the other run-based
// CLI tests in this file.
#[cfg(target_os = "linux")]
#[test]
fn repl_accumulates_multiline_expression_input() {
    let output = typelisp_with_stdin(&["repl"], "(+ 1\n  2)\n.exit\n");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "3\n");
    assert_eq!(stderr(&output), "");
}

#[cfg(target_os = "linux")]
#[test]
fn repl_delimiters_ignore_strings_chars_and_comments() {
    let input = r#"(begin
  (print-string "not closing )")
  #\)'
  ; comment with ( and )
  1)
.exit
"#;
    let output = typelisp_with_stdin(&["repl"], input);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    // The string body prints first (no newline), then the begin's i64 value 1.
    // Reaching this output at all proves the `)`/`(` inside the string, char,
    // and comment never tripped the input delimiter counter.
    assert_eq!(stdout(&output), "not closing )1\n");
    let stderr = stderr(&output);
    assert!(
        !stderr.contains("incomplete REPL input"),
        "stderr:\n{}",
        stderr
    );
}

#[test]
fn repl_eof_during_incomplete_input_reports_diagnostic() {
    let output = typelisp_with_stdin(&["repl"], "(+ 1\n");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "");
    assert!(
        stderr(&output).contains("Error: incomplete REPL input at EOF"),
        "stderr:\n{}",
        stderr(&output)
    );
}

#[cfg(target_os = "linux")]
#[test]
fn repl_evaluates_scalar_expression() {
    let output = typelisp_with_stdin(&["repl"], "(+ 20 22)\n.exit\n");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "42\n");
    assert_eq!(stderr(&output), "");
}

#[cfg(target_os = "linux")]
#[test]
fn repl_expression_uses_session_declaration() {
    let output = typelisp_with_stdin(
        &["repl"],
        "(define (double [x : i64]) : i64 (* x 2))\n(double 21)\n.exit\n",
    );

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "42\n");
    assert_eq!(stderr(&output), "");
}

#[cfg(target_os = "linux")]
#[test]
fn repl_prints_supported_display_types() {
    let output = typelisp_with_stdin(
        &["repl"],
        "10\ntrue\n3.5\n#Z'\n\"hi\"\n(print-newline)\n.exit\n",
    );

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    // i64, bool, f64, char, String each render with one trailing newline; the
    // unit `(print-newline)` runs for its effect (a blank line).
    assert_eq!(stdout(&output), "10\ntrue\n3.5\nZ\nhi\n\n");
    assert_eq!(stderr(&output), "");
}

#[cfg(target_os = "linux")]
#[test]
fn repl_invalid_expression_does_not_disturb_session() {
    let output = typelisp_with_stdin(
        &["repl"],
        "(define (double [x : i64]) : i64 (* x 2))\n(+ 1 true)\n(double 4)\n.exit\n",
    );

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    // The ill-typed expression is rejected but the session is untouched, so the
    // later call still resolves the persisted declaration.
    assert_eq!(stdout(&output), "8\n");
    assert!(
        stderr(&output).contains("numeric types"),
        "stderr:\n{}",
        stderr(&output)
    );
}

#[test]
fn repl_rejects_undisplayable_result_type() {
    let output = typelisp_with_stdin(&["repl"], "(tuple 1 2)\n.exit\n");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "");
    assert!(
        stderr(&output).contains("cannot display a value of type"),
        "stderr:\n{}",
        stderr(&output)
    );
}

#[test]
fn repl_rejects_duplicate_declaration() {
    let output = typelisp_with_stdin(
        &["repl"],
        "(define (f) : i64 1)\n(define (f) : i64 2)\n.exit\n",
    );

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "");
    assert!(
        stderr(&output).contains("duplicate top-level name"),
        "stderr:\n{}",
        stderr(&output)
    );
}

#[test]
fn repl_reports_errors_and_recovers_for_next_input() {
    let input = r#"#\spcae'
(+ 1)
.help
.exit
"#;
    let output = typelisp_with_stdin(&["repl"], input);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert!(stdout(&output).contains("TypeLisp REPL commands:"));
    let stderr = stderr(&output);
    assert!(
        stderr.contains("REPL input error: lexer error"),
        "stderr:\n{}",
        stderr
    );
    assert!(
        stderr.contains("unknown named character literal"),
        "stderr:\n{}",
        stderr
    );
    assert!(
        stderr.contains("REPL parse error: parse error"),
        "stderr:\n{}",
        stderr
    );
}

#[test]
fn repl_type_prints_literal_and_session_decl_types() {
    let output = typelisp_with_stdin(
        &["repl"],
        ".type 42\n(define answer : i64 41)\n.type (+ answer 1)\n.exit\n",
    );

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    assert_eq!(stdout(&output), "i64\ni64\n");
}

#[test]
fn repl_type_reports_parse_errors_and_continues() {
    let output = typelisp_with_stdin(&["repl"], ".type (+ 1)\n.type true\n.exit\n");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "bool\n");
    let stderr = stderr(&output);
    assert!(stderr.contains("error[E0100]"), "stderr:\n{}", stderr);
    assert!(stderr.contains("--> <repl>:"), "stderr:\n{}", stderr);
}

#[test]
fn repl_type_reports_type_errors_and_keeps_session() {
    let output = typelisp_with_stdin(
        &["repl"],
        "(define answer : i64 41)\n.type (+ answer true)\n.type answer\n.exit\n",
    );

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "i64\n");
    let stderr = stderr(&output);
    assert!(stderr.contains("error[E0200]"), "stderr:\n{}", stderr);
    assert!(
        stderr.contains("arithmetic operator requires numeric types"),
        "stderr:\n{}",
        stderr
    );
}

#[test]
fn repl_type_rejects_declarations_without_mutating_session() {
    let output = typelisp_with_stdin(
        &["repl"],
        ".type (define answer : i64 41)\n.type answer\n.exit\n",
    );

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "");
    let stderr = stderr(&output);
    assert!(
        stderr.contains("Error: .type expects an expression, got a declaration"),
        "stderr:\n{}",
        stderr
    );
    assert!(
        stderr.contains("unbound variable: answer"),
        "stderr:\n{}",
        stderr
    );
}

#[test]
fn debug_tokenize_matches_top_level_alias() {
    let dir = fixture_dir("debug-tokenize");
    let source = dir.join("main.tl");
    fs::write(&source, "(define (main) : i64 42)\n").expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");

    let alias = typelisp(&["tokenize", source_arg]);
    let debug = typelisp(&["debug", "tokenize", source_arg]);

    assert!(alias.status.success(), "alias stderr:\n{}", stderr(&alias));
    assert!(debug.status.success(), "debug stderr:\n{}", stderr(&debug));
    assert_eq!(debug.stdout, alias.stdout);
    assert_eq!(debug.stderr, alias.stderr);
}

#[test]
fn tokenize_preserves_public_frontend_token_spellings() {
    let dir = fixture_dir("selfhost-tokenize");
    let source = dir.join("main.tl");
    fs::write(&source, "(define (main [x : i64]) : i64 (+ x 1))\n").expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["tokenize", source_arg]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    assert_eq!(
        stdout(&output).replace("\r\n", "\n"),
        "(\ndefine\n(\nmain\n[\nx\n:\ni64\n]\n)\n:\ni64\n(\n+\nx\n1\n)\n)\n"
    );
}

#[test]
fn parse_prints_selfhost_program_summary() {
    let dir = fixture_dir("selfhost-parse");
    let source = write_main_source(&dir);
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["parse", source_arg]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let out = stdout(&output);
    assert!(out.contains("Program {"), "stdout:\n{}", out);
    assert!(out.contains("DefFn { name: \"main\""), "stdout:\n{}", out);
    assert!(out.contains("Literal(Int(42))"), "stdout:\n{}", out);
}

#[test]
fn parse_renders_newer_selfhost_ast_forms() {
    let dir = fixture_dir("selfhost-parse-new-forms");
    let source = dir.join("main.tl");
    fs::write(
        &source,
        "(comptime-decl (defstruct Point (x i64)))\n\
         (define (main [n : i64] [xs : (Array i64)]) : i64\n\
           (begin\n\
             (comptime (type (Array i64 4)))\n\
             (with-arena r (int->string 41))\n\
             (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i))))\n",
    )
    .expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");

    let alias = typelisp(&["parse", source_arg]);
    let debug = typelisp(&["debug", "parse", source_arg]);

    assert!(alias.status.success(), "alias stderr:\n{}", stderr(&alias));
    assert!(debug.status.success(), "debug stderr:\n{}", stderr(&debug));
    assert_eq!(debug.stdout, alias.stdout);
    assert_eq!(debug.stderr, alias.stderr);
    assert_eq!(stderr(&alias), "");
    let out = stdout(&alias);
    assert!(
        out.contains("ComptimeDecl { template: DefStruct"),
        "stdout:\n{}",
        out
    );
    assert!(
        out.contains("TypeLiteral { ty: Array(I64, 4) }"),
        "stdout:\n{}",
        out
    );
    assert!(
        out.contains("WithRegion { region: \"r\""),
        "stdout:\n{}",
        out
    );
    assert!(out.contains("SpmdReduce { op: Sum"), "stdout:\n{}", out);
    assert!(out.contains("index: \"i\""), "stdout:\n{}", out);
    assert!(
        out.contains("value: ArrayRef { expr: Var(\"xs\"), index: Var(\"i\") }"),
        "stdout:\n{}",
        out
    );
}

#[test]
fn debug_parse_matches_top_level_alias() {
    let dir = fixture_dir("debug-parse");
    let source = write_main_source(&dir);
    let source_arg = source.to_str().expect("source path is utf-8");

    let alias = typelisp(&["parse", source_arg]);
    let debug = typelisp(&["debug", "parse", source_arg]);

    assert!(alias.status.success(), "alias stderr:\n{}", stderr(&alias));
    assert!(debug.status.success(), "debug stderr:\n{}", stderr(&debug));
    assert_eq!(debug.stdout, alias.stdout);
    assert_eq!(debug.stderr, alias.stderr);
}

#[test]
fn debug_check_matches_top_level_alias_with_stdlib_root() {
    let dir = fixture_dir("debug-check");
    let app_dir = dir.join("app");
    let root_dir = dir.join("root");
    fs::create_dir_all(&app_dir).expect("create app dir");
    fs::create_dir_all(&root_dir).expect("create stdlib root dir");

    fs::write(root_dir.join("helper.tl"), "(define (helper) : i64 42)\n").expect("write helper");
    let source = app_dir.join("main.tl");
    fs::write(
        &source,
        "(import \"stdlib/helper.tl\")\n(define (main) : i64 (helper))\n",
    )
    .expect("write source");

    let source_arg = source.to_str().expect("source path is utf-8");
    let root_arg = root_dir.to_str().expect("root path is utf-8");
    let alias = typelisp(&["check", source_arg, "--stdlib-root", root_arg]);
    let debug = typelisp(&["debug", "check", source_arg, "--stdlib-root", root_arg]);

    assert!(alias.status.success(), "alias stderr:\n{}", stderr(&alias));
    assert!(debug.status.success(), "debug stderr:\n{}", stderr(&debug));
    assert_eq!(debug.stdout, alias.stdout);
    assert_eq!(debug.stderr, alias.stderr);
    assert_eq!(stdout(&debug), "Type checking passed!\n");
}

#[test]
fn compile_accepts_explicit_scalar_backend_mode() {
    let dir = fixture_dir("backend-mode-scalar");
    let source = write_main_source(&dir);
    let output_path = dir.join("main.s");
    let source_arg = source.to_str().expect("source path is utf-8");
    let output_arg = output_path.to_str().expect("output path is utf-8");

    let output = typelisp(&[
        "compile",
        source_arg,
        "--backend-mode",
        "scalar",
        "-o",
        output_arg,
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    assert!(output_path.exists(), "compile did not write assembly");
    let asm = fs::read_to_string(&output_path).expect("read assembly");
    assert!(asm.contains("main:"), "assembly:\n{}", asm);
}

#[test]
fn compile_accepts_avx2_backend_mode_for_scalar_program() {
    let dir = fixture_dir("backend-mode-avx2");
    let source = write_main_source(&dir);
    let output_path = dir.join("main.s");
    let source_arg = source.to_str().expect("source path is utf-8");
    let output_arg = output_path.to_str().expect("output path is utf-8");

    let output = typelisp(&[
        "compile",
        source_arg,
        "--backend-mode",
        "avx2",
        "-o",
        output_arg,
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "");
    let asm = fs::read_to_string(&output_path).expect("read assembly");
    assert!(asm.contains("main:"), "assembly:\n{}", asm);
    assert!(asm.contains("vzeroupper"), "assembly:\n{}", asm);
}

#[test]
fn compile_accepts_windows_target_aliases() {
    for target in ["windows-x86_64", "windows_x86_64"] {
        let dir = fixture_dir(&format!("target-{target}"));
        let source = dir.join("main.tl");
        fs::write(
            &source,
            r#"(define (main) : i64
  (begin
    (print-string "hi")
    42))
"#,
        )
        .expect("write source");
        let output_path = dir.join("main.s");
        let source_arg = source.to_str().expect("source path is utf-8");
        let output_arg = output_path.to_str().expect("output path is utf-8");

        let output = typelisp(&["compile", source_arg, "--target", target, "-o", output_arg]);

        assert!(
            output.status.success(),
            "{target} failed\nstdout:\n{}\nstderr:\n{}",
            stdout(&output),
            stderr(&output)
        );
        assert_eq!(stderr(&output), "", "{target} stderr");
        let asm = fs::read_to_string(&output_path).expect("read assembly");
        assert!(
            asm.contains("    .globl main"),
            "{target} assembly:\n{}",
            asm
        );
        assert!(
            !asm.contains("    .globl _start"),
            "{target} assembly:\n{}",
            asm
        );
        assert!(
            asm.contains("    .extern _write"),
            "{target} assembly:\n{}",
            asm
        );
        assert!(
            asm.contains("    sub $32, %rsp"),
            "{target} assembly:\n{}",
            asm
        );
    }
}

#[test]
fn target_flags_reject_unknown_target_across_commands() {
    let dir = fixture_dir("target-unknown");
    let source = write_main_source(&dir);
    let source_arg = source.to_str().expect("source path is utf-8");

    for (args, expected) in [
        (
            vec!["compile", source_arg, "--target", "plan9-x86_64"],
            "Error: unknown target 'plan9-x86_64'. Expected linux-x86_64 or windows-x86_64",
        ),
        (
            vec!["build", source_arg, "--target", "plan9-x86_64"],
            "build: unknown target plan9-x86_64",
        ),
        (
            vec!["run", source_arg, "--target", "plan9-x86_64"],
            "run: unknown target plan9-x86_64",
        ),
    ] {
        let output = typelisp(&args);

        assert!(
            !output.status.success(),
            "{args:?} unexpectedly succeeded\nstdout:\n{}\nstderr:\n{}",
            stdout(&output),
            stderr(&output)
        );
        assert_eq!(stdout(&output), "", "{args:?} wrote stdout");
        assert!(
            stderr(&output).contains(expected),
            "{args:?} stderr:\n{}",
            stderr(&output)
        );
    }
}

#[test]
fn compile_accepts_implemented_backend_modes() {
    for mode in ["scalar", "avx2", "avx512"] {
        let dir = fixture_dir(&format!("backend-mode-{mode}-ok"));
        let source = write_main_source(&dir);
        let source_arg = source.to_str().expect("source path is utf-8");

        let output = typelisp(&["compile", source_arg, "--backend-mode", mode]);

        assert!(
            output.status.success(),
            "mode {mode} should succeed\nstdout:\n{}\nstderr:\n{}",
            stdout(&output),
            stderr(&output)
        );
    }
}

#[test]
fn compile_rejects_unknown_backend_mode() {
    let dir = fixture_dir("backend-mode-unknown");
    let source = write_main_source(&dir);
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["compile", source_arg, "--backend-mode", "neon"]);

    assert!(!output.status.success());
    assert_eq!(stdout(&output), "");
    assert!(
        stderr(&output)
            .contains("Error: unknown backend mode 'neon'. Expected scalar, avx2, or avx512"),
        "stderr:\n{}",
        stderr(&output)
    );
}

#[cfg(target_os = "linux")]
#[test]
fn selfhost_compile_cli_driver_writes_assembly_and_reports_errors() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let driver_source = manifest_dir.join("selfhost").join("compile.tl");
    let dir = fixture_dir("selfhost-compile-cli");
    let driver_bin = dir.join("selfhost-compile");
    let driver_source_arg = driver_source.to_str().expect("driver path is utf-8");
    let driver_bin_arg = driver_bin.to_str().expect("driver output path is utf-8");

    let build = typelisp(&["build", driver_source_arg, "-o", driver_bin_arg]);
    assert!(
        build.status.success(),
        "selfhost compile driver build failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&build),
        stderr(&build)
    );

    let source = dir.join("main.tl");
    let explicit_asm = dir.join("custom-output.s");
    fs::write(&source, "(define (main) : i64 42)\n").expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");
    let explicit_asm_arg = explicit_asm.to_str().expect("explicit asm path is utf-8");

    let explicit = driver_output(&driver_bin, &[source_arg, "-o", explicit_asm_arg]);
    assert!(
        explicit.status.success(),
        "selfhost compile -o failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&explicit),
        stderr(&explicit)
    );
    assert_eq!(stdout(&explicit), "");
    assert_eq!(stderr(&explicit), "");
    let explicit_text = fs::read_to_string(&explicit_asm).expect("read explicit asm");
    assert!(
        explicit_text.contains("main:"),
        "explicit assembly:\n{}",
        explicit_text
    );
    assert!(
        explicit_text.contains(".globl _start\n"),
        "default assembly should stay on the Linux entry path:\n{}",
        explicit_text
    );

    let stdlib_root = dir.join("repo-stdlib");
    fs::create_dir_all(&stdlib_root).expect("create selfhost compile stdlib root");
    fs::write(
        stdlib_root.join("math.tl"),
        "(define (bump [x : i64]) : i64 (+ x 1))\n",
    )
    .expect("write selfhost compile stdlib fixture");
    let stdlib_source = dir.join("stdlib-main.tl");
    let stdlib_asm = dir.join("stdlib-main.s");
    fs::write(
        &stdlib_source,
        "(import \"stdlib/math.tl\")\n(define (main) : i64 (bump 41))\n",
    )
    .expect("write selfhost compile stdlib-root source");
    let stdlib_source_arg = stdlib_source.to_str().expect("stdlib source path is utf-8");
    let stdlib_asm_arg = stdlib_asm.to_str().expect("stdlib asm path is utf-8");
    let stdlib_root_arg = stdlib_root.to_str().expect("stdlib root path is utf-8");
    let stdlib_compile = driver_output(
        &driver_bin,
        &[
            stdlib_source_arg,
            "--stdlib-root",
            stdlib_root_arg,
            "-o",
            stdlib_asm_arg,
        ],
    );
    assert!(
        stdlib_compile.status.success(),
        "selfhost compile stdlib-root failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&stdlib_compile),
        stderr(&stdlib_compile)
    );
    assert_eq!(stdout(&stdlib_compile), "");
    assert_eq!(stderr(&stdlib_compile), "");
    let stdlib_asm_text = fs::read_to_string(&stdlib_asm).expect("read stdlib asm");
    assert!(
        stdlib_asm_text.contains("bump:"),
        "stdlib-root assembly missing imported function:\n{}",
        stdlib_asm_text
    );

    let explicit_linux_asm = dir.join("explicit-linux.s");
    let explicit_linux_asm_arg = explicit_linux_asm
        .to_str()
        .expect("explicit linux asm path is utf-8");
    let explicit_linux = driver_output(
        &driver_bin,
        &[
            source_arg,
            "--target",
            "linux-x86_64",
            "-o",
            explicit_linux_asm_arg,
        ],
    );
    assert!(
        explicit_linux.status.success(),
        "selfhost compile explicit Linux target failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&explicit_linux),
        stderr(&explicit_linux)
    );
    assert_eq!(stdout(&explicit_linux), "");
    assert_eq!(stderr(&explicit_linux), "");
    let explicit_linux_text =
        fs::read_to_string(&explicit_linux_asm).expect("read explicit Linux asm");
    assert_eq!(
        explicit_linux_text, explicit_text,
        "explicit Linux target should match default selfhost compile output"
    );

    let windows_asm = dir.join("windows.s");
    let windows_asm_arg = windows_asm.to_str().expect("windows asm path is utf-8");
    let windows = driver_output(
        &driver_bin,
        &[
            source_arg,
            "--target",
            "windows-x86_64",
            "-o",
            windows_asm_arg,
        ],
    );
    assert!(
        windows.status.success(),
        "selfhost compile Windows target failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&windows),
        stderr(&windows)
    );
    assert_eq!(stdout(&windows), "");
    assert_eq!(stderr(&windows), "");
    let windows_text = fs::read_to_string(&windows_asm).expect("read Windows target asm");
    assert!(
        windows_text.contains(".globl main\n"),
        "Windows target assembly missing main export:\n{}",
        windows_text
    );
    assert!(
        !windows_text.contains(".globl _start\n"),
        "Windows target assembly should not emit Linux _start:\n{}",
        windows_text
    );

    let comptime_type_source = dir.join("comptime-type.tl");
    let comptime_type_asm = dir.join("comptime-type.s");
    fs::write(
        &comptime_type_source,
        "(define (alloc [comptime T : type] [n : i64]) : (Array i64) (make-array T n))
(define (main) : (Array i64) (alloc (type i64) 4))
",
    )
    .expect("write comptime type source");
    let comptime_type_source_arg = comptime_type_source
        .to_str()
        .expect("comptime type source path is utf-8");
    let comptime_type_asm_arg = comptime_type_asm
        .to_str()
        .expect("comptime type asm path is utf-8");
    let comptime_type = driver_output(
        &driver_bin,
        &[comptime_type_source_arg, "-o", comptime_type_asm_arg],
    );
    assert!(
        comptime_type.status.success(),
        "selfhost compile comptime type source failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&comptime_type),
        stderr(&comptime_type)
    );
    let comptime_type_text =
        fs::read_to_string(&comptime_type_asm).expect("read comptime type asm");
    assert!(
        comptime_type_text.contains("__tl_specialized_alloc_type_i64_none"),
        "comptime type assembly:\n{}",
        comptime_type_text
    );

    let region_source = dir.join("region-ok.tl");
    let region_asm = dir.join("region-ok.s");
    fs::write(
        &region_source,
        "(define (main) : i64\n  (with-arena r\n    (let ([s : String (int->string 41)])\n      (string-length s))))\n",
    )
    .expect("write region source");
    let region_source_arg = region_source.to_str().expect("region source path is utf-8");
    let region_asm_arg = region_asm.to_str().expect("region asm path is utf-8");
    let region_ok = driver_output(&driver_bin, &[region_source_arg, "-o", region_asm_arg]);
    assert!(
        region_ok.status.success(),
        "selfhost compile region source failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&region_ok),
        stderr(&region_ok)
    );
    let region_asm_text = fs::read_to_string(&region_asm).expect("read region asm");
    for needle in [
        "    call tl_region_mark\n",
        "    call tl_region_reset\n",
        "tl_region_mark:\n",
        "tl_region_reset:\n",
    ] {
        assert!(
            region_asm_text.contains(needle),
            "region assembly missing {needle:?}:\n{region_asm_text}",
        );
    }

    let default_source = dir.join("default.tl");
    fs::write(&default_source, "(define (main) : i64 7)\n").expect("write default source");
    let default_source_arg = default_source
        .to_str()
        .expect("default source path is utf-8");
    let default = driver_output(&driver_bin, &[default_source_arg]);
    assert!(
        default.status.success(),
        "selfhost compile default output failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&default),
        stderr(&default)
    );
    assert_eq!(stdout(&default), "");
    assert_eq!(stderr(&default), "");
    assert!(
        default_source.with_extension("s").is_file(),
        "default .s output was not written"
    );

    let opt_source = dir.join("opt-level.tl");
    fs::write(&opt_source, "(define (main) : i64 (+ 20 22))\n").expect("write opt-level source");
    let opt_source_arg = opt_source.to_str().expect("opt source path is utf-8");
    let opt_default_asm = dir.join("opt-default.s");
    let opt_default_asm_arg = opt_default_asm
        .to_str()
        .expect("opt default asm path is utf-8");
    let opt_default = driver_output(&driver_bin, &[opt_source_arg, "-o", opt_default_asm_arg]);
    assert!(
        opt_default.status.success(),
        "selfhost compile default opt level failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&opt_default),
        stderr(&opt_default)
    );
    let opt_default_text = fs::read_to_string(&opt_default_asm).expect("read default opt asm");

    let mut opt_level_texts = Vec::new();
    for level in ["0", "1", "2", "3"] {
        let asm_path = dir.join(format!("opt-level-{level}.s"));
        let asm_arg = asm_path.to_str().expect("opt-level asm path is utf-8");
        let output = driver_output(
            &driver_bin,
            &[opt_source_arg, "--opt-level", level, "-o", asm_arg],
        );
        assert!(
            output.status.success(),
            "selfhost compile --opt-level {level} failed\nstdout:\n{}\nstderr:\n{}",
            stdout(&output),
            stderr(&output)
        );
        opt_level_texts.push(
            fs::read_to_string(&asm_path)
                .unwrap_or_else(|err| panic!("read opt-level {level} asm: {err}")),
        );
    }
    assert!(
        opt_level_texts[0].contains("    addq %rbx, %rax\n"),
        "opt-level 0 should leave lowered arithmetic in assembly:\n{}",
        opt_level_texts[0]
    );
    assert!(
        !opt_level_texts[2].contains("    addq %rbx, %rax\n"),
        "opt-level 2 should fold constant arithmetic:\n{}",
        opt_level_texts[2]
    );
    assert_eq!(
        opt_default_text, opt_level_texts[2],
        "omitted --opt-level should use the shared default level 2"
    );
    assert_eq!(
        opt_level_texts[2], opt_level_texts[3],
        "opt-level 3 is currently documented as level-2 equivalent"
    );

    let missing_opt = driver_output(&driver_bin, &[opt_source_arg, "--opt-level"]);
    assert!(!missing_opt.status.success());
    assert_eq!(stdout(&missing_opt), "");
    assert!(
        stderr(&missing_opt).contains("compile: --opt-level requires a value"),
        "stderr:\n{}",
        stderr(&missing_opt)
    );

    let duplicate_opt = driver_output(
        &driver_bin,
        &[opt_source_arg, "--opt-level", "1", "--opt-level", "2"],
    );
    assert!(!duplicate_opt.status.success());
    assert_eq!(stdout(&duplicate_opt), "");
    assert!(
        stderr(&duplicate_opt).contains("compile: --opt-level was provided more than once"),
        "stderr:\n{}",
        stderr(&duplicate_opt)
    );

    let invalid_opt = driver_output(&driver_bin, &[opt_source_arg, "--opt-level", "4"]);
    assert!(!invalid_opt.status.success());
    assert_eq!(stdout(&invalid_opt), "");
    assert!(
        stderr(&invalid_opt).contains("compile: invalid --opt-level 4; expected 0, 1, 2, or 3"),
        "stderr:\n{}",
        stderr(&invalid_opt)
    );

    let bad_target_asm = dir.join("bad-target.s");
    let bad_target_asm_arg = bad_target_asm
        .to_str()
        .expect("bad target asm path is utf-8");
    let bad_target = driver_output(
        &driver_bin,
        &[
            source_arg,
            "--target",
            "plan9-x86_64",
            "-o",
            bad_target_asm_arg,
        ],
    );
    assert!(!bad_target.status.success());
    assert_eq!(stdout(&bad_target), "");
    assert!(
        stderr(&bad_target).contains(
            "Error: unknown target 'plan9-x86_64'. Expected linux-x86_64 or windows-x86_64"
        ),
        "stderr:\n{}",
        stderr(&bad_target)
    );
    assert!(
        !bad_target_asm.exists(),
        "invalid target should not write assembly"
    );

    let explicit_ir = dir.join("custom-output.ir");
    let explicit_ir_arg = explicit_ir.to_str().expect("explicit ir path is utf-8");
    let emit_ir = driver_output(
        &driver_bin,
        &[source_arg, "--emit-ir", "-o", explicit_ir_arg],
    );
    assert!(
        emit_ir.status.success(),
        "selfhost compile --emit-ir failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&emit_ir),
        stderr(&emit_ir)
    );
    assert_eq!(stdout(&emit_ir), "");
    assert_eq!(stderr(&emit_ir), "");
    let explicit_ir_text = fs::read_to_string(&explicit_ir).expect("read explicit ir summary");
    for needle in [
        "typelisp-ir-summary v1\n",
        "functions 1\n",
        "instructions ",
        "score ",
    ] {
        assert!(
            explicit_ir_text.contains(needle),
            "IR summary missing {needle:?}:\n{explicit_ir_text}",
        );
    }

    let default_ir = driver_output(&driver_bin, &[source_arg, "--emit-ir"]);
    assert!(
        default_ir.status.success(),
        "selfhost compile default --emit-ir failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&default_ir),
        stderr(&default_ir)
    );
    assert_eq!(stdout(&default_ir), "");
    assert_eq!(stderr(&default_ir), "");
    let default_ir_path = source.with_extension("ir");
    assert!(
        default_ir_path.is_file(),
        "default --emit-ir output was not written"
    );
    let default_ir_text = fs::read_to_string(&default_ir_path).expect("read default ir summary");
    assert!(
        default_ir_text.contains("typelisp-ir-summary v1\n"),
        "default IR summary:\n{default_ir_text}"
    );

    let bad_source = dir.join("bad.tl");
    let bad_asm = dir.join("bad.s");
    fs::write(&bad_source, "(define (main) : i64 true)\n").expect("write bad source");
    let bad_source_arg = bad_source.to_str().expect("bad source path is utf-8");
    let bad_asm_arg = bad_asm.to_str().expect("bad asm path is utf-8");
    let failure = driver_output(&driver_bin, &[bad_source_arg, "-o", bad_asm_arg]);
    assert!(!failure.status.success());
    assert_eq!(stdout(&failure), "");
    assert!(
        stderr(&failure).contains("typecheck: return type mismatch"),
        "stderr:\n{}",
        stderr(&failure)
    );
    assert!(
        !bad_asm.exists(),
        "failing selfhost compile should not write assembly"
    );

    let bad_region_source = dir.join("region-bad.tl");
    let bad_region_asm = dir.join("region-bad.s");
    fs::write(
        &bad_region_source,
        "(define (main) : String\n  (with-arena r (int->string 41)))\n",
    )
    .expect("write bad region source");
    let bad_region_source_arg = bad_region_source
        .to_str()
        .expect("bad region source path is utf-8");
    let bad_region_asm_arg = bad_region_asm
        .to_str()
        .expect("bad region asm path is utf-8");
    let bad_region = driver_output(
        &driver_bin,
        &[bad_region_source_arg, "-o", bad_region_asm_arg],
    );
    assert!(!bad_region.status.success());
    assert_eq!(stdout(&bad_region), "");
    assert!(
        stderr(&bad_region).contains("region-tagged value")
            && stderr(&bad_region).contains("cannot escape with-arena"),
        "stderr:\n{}",
        stderr(&bad_region)
    );
    assert!(
        !bad_region_asm.exists(),
        "bad region selfhost compile should not write assembly"
    );

    let lower_source = dir.join("lower.tl");
    let lower_asm = dir.join("lower.s");
    fs::write(
        &lower_source,
        "(define (main) : (Tuple i64 bool)\n  (tuple 1 true))\n",
    )
    .expect("write lowerer-error source");
    let lower_source_arg = lower_source
        .to_str()
        .expect("lowerer-error source path is utf-8");
    let lower_asm_arg = lower_asm.to_str().expect("lowerer-error asm path is utf-8");
    let lower_failure = driver_output(&driver_bin, &[lower_source_arg, "-o", lower_asm_arg]);
    assert!(!lower_failure.status.success());
    assert_eq!(stdout(&lower_failure), "");
    let expected = format!(
        "{}:2:3: lower: unsupported expression",
        lower_source.display()
    );
    assert!(
        stderr(&lower_failure).contains(&expected),
        "expected {expected:?}\nstderr:\n{}",
        stderr(&lower_failure)
    );
    assert!(
        !lower_asm.exists(),
        "lowerer-error selfhost compile should not write assembly"
    );

    let malformed_source = dir.join("malformed.tl");
    let malformed_asm = dir.join("malformed.s");
    fs::write(&malformed_source, ")\n").expect("write malformed source");
    let malformed_source_arg = malformed_source
        .to_str()
        .expect("malformed source path is utf-8");
    let malformed_asm_arg = malformed_asm.to_str().expect("malformed asm path is utf-8");
    let parse_failure = driver_output(
        &driver_bin,
        &[malformed_source_arg, "-o", malformed_asm_arg],
    );
    assert!(!parse_failure.status.success());
    assert_eq!(stdout(&parse_failure), "");
    let expected = format!("{}:1:1: reader: unexpected ')'", malformed_source.display());
    assert!(
        stderr(&parse_failure).contains(&expected),
        "expected {expected:?}\nstderr:\n{}",
        stderr(&parse_failure)
    );
    assert!(
        !malformed_asm.exists(),
        "malformed selfhost compile should not write assembly"
    );
}

#[cfg(target_os = "linux")]
#[test]
fn selfhost_test_planner_threads_opt_level_into_harness_compile() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let driver_source = manifest_dir.join("selfhost").join("test.tl");
    let dir = fixture_dir("selfhost-test-opt-level");
    let driver_bin = dir.join("selfhost-test");
    let driver_source_arg = driver_source.to_str().expect("driver path is utf-8");
    let driver_bin_arg = driver_bin.to_str().expect("driver output path is utf-8");

    let build = typelisp(&["build", driver_source_arg, "-o", driver_bin_arg]);
    assert!(
        build.status.success(),
        "selfhost test planner build failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&build),
        stderr(&build)
    );

    let source = dir.join("inline-opt.tl");
    fs::write(
        &source,
        "(extern sink : (-> i64 unit))\n(test folded\n  (sink (+ 20 22)))\n",
    )
    .expect("write inline opt-level test source");
    let source_arg = source.to_str().expect("source path is utf-8");
    let scratch_asm = PathBuf::from(format!("{source_arg}.test.s"));

    let default = driver_output(&driver_bin, &[source_arg]);
    assert!(
        default.status.success(),
        "selfhost test default opt level failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&default),
        stderr(&default)
    );
    assert_eq!(stderr(&default), "");
    assert!(
        stdout(&default).contains("run-scratch-assembly"),
        "stdout:\n{}",
        stdout(&default)
    );
    let default_text =
        fs::read_to_string(&scratch_asm).expect("read default inline test harness asm");

    let mut opt_level_texts = Vec::new();
    for level in ["0", "1", "2", "3"] {
        let _ = fs::remove_file(&scratch_asm);
        let output = driver_output(&driver_bin, &[source_arg, "--opt-level", level]);
        assert!(
            output.status.success(),
            "selfhost test --opt-level {level} failed\nstdout:\n{}\nstderr:\n{}",
            stdout(&output),
            stderr(&output)
        );
        assert_eq!(stderr(&output), "");
        assert!(
            stdout(&output).contains("run-scratch-assembly"),
            "stdout:\n{}",
            stdout(&output)
        );
        opt_level_texts.push(
            fs::read_to_string(&scratch_asm)
                .unwrap_or_else(|err| panic!("read test opt-level {level} asm: {err}")),
        );
    }

    assert!(
        opt_level_texts[0].contains(
            "    addq %rbx, %rax\n    movq %rax, %r14\n    movq %r14, %rdi\n    call sink\n"
        ),
        "test opt-level 0 should leave lowered arithmetic in harness assembly:\n{}",
        opt_level_texts[0]
    );
    assert!(
        opt_level_texts[2].contains("    movq $42, %rdi\n    call sink\n"),
        "test opt-level 2 should fold harness arithmetic:\n{}",
        opt_level_texts[2]
    );
    assert_eq!(
        default_text, opt_level_texts[2],
        "omitted test --opt-level should use the shared default level 2"
    );
    assert_eq!(
        opt_level_texts[2], opt_level_texts[3],
        "test opt-level 3 is currently documented as level-2 equivalent"
    );

    let check = driver_output(&driver_bin, &[source_arg, "--check", "--opt-level", "3"]);
    assert!(
        check.status.success(),
        "selfhost test --check --opt-level failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&check),
        stderr(&check)
    );
    assert!(stdout(&check).contains("TypeLisp test typecheck passed: 1 test(s)"));

    let missing_opt = driver_output(&driver_bin, &[source_arg, "--opt-level"]);
    assert!(!missing_opt.status.success());
    assert_eq!(stdout(&missing_opt), "");
    assert!(
        stderr(&missing_opt).contains("test: --opt-level requires a value"),
        "stderr:\n{}",
        stderr(&missing_opt)
    );

    let duplicate_opt = driver_output(
        &driver_bin,
        &[source_arg, "--opt-level", "1", "--opt-level", "2"],
    );
    assert!(!duplicate_opt.status.success());
    assert_eq!(stdout(&duplicate_opt), "");
    assert!(
        stderr(&duplicate_opt).contains("test: --opt-level was provided more than once"),
        "stderr:\n{}",
        stderr(&duplicate_opt)
    );

    let invalid_opt = driver_output(&driver_bin, &[source_arg, "--opt-level", "4"]);
    assert!(!invalid_opt.status.success());
    assert_eq!(stdout(&invalid_opt), "");
    assert!(
        stderr(&invalid_opt).contains("test: invalid --opt-level 4; expected 0, 1, 2, or 3"),
        "stderr:\n{}",
        stderr(&invalid_opt)
    );
}

#[cfg(target_os = "linux")]
#[test]
fn selfhost_build_run_planners_emit_host_action_plans() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dir = fixture_dir("selfhost-build-run-planners");

    let build_driver = manifest_dir.join("selfhost").join("build.tl");
    let build_bin = dir.join("selfhost-build-planner");
    let build_driver_arg = build_driver.to_str().expect("build driver path is utf-8");
    let build_bin_arg = build_bin
        .to_str()
        .expect("build planner output path is utf-8");
    let build = typelisp(&["build", build_driver_arg, "-o", build_bin_arg]);
    assert!(
        build.status.success(),
        "selfhost build planner build failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&build),
        stderr(&build)
    );

    let run_driver = manifest_dir.join("selfhost").join("run.tl");
    let run_bin = dir.join("selfhost-run-planner");
    let run_driver_arg = run_driver.to_str().expect("run driver path is utf-8");
    let run_bin_arg = run_bin.to_str().expect("run planner output path is utf-8");
    let build_run = typelisp(&["build", run_driver_arg, "-o", run_bin_arg]);
    assert!(
        build_run.status.success(),
        "selfhost run planner build failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&build_run),
        stderr(&build_run)
    );

    let spaced = dir.join("with space");
    fs::create_dir_all(&spaced).expect("create spaced planner fixture dir");
    let source = spaced.join("main file.tl");
    let output_path = spaced.join("the program");
    let stdlib_one = spaced.join("stdlib one");
    let source_arg = source.to_str().expect("source path is utf-8");
    let output_arg = output_path.to_str().expect("output path is utf-8");
    let stdlib_one_arg = stdlib_one.to_str().expect("stdlib path is utf-8");
    let stdlib_two_arg = "stdlib:two";

    let build_plan = Command::new(&build_bin)
        .arg(source_arg)
        .arg("-o")
        .arg(output_arg)
        .arg("--target")
        .arg("windows-x86_64")
        .arg("--backend-mode")
        .arg("avx2")
        .arg("--stdlib-root")
        .arg(stdlib_one_arg)
        .arg("--stdlib-root")
        .arg(stdlib_two_arg)
        .output()
        .expect("run selfhost build planner");
    assert!(
        build_plan.status.success(),
        "selfhost build planner failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&build_plan),
        stderr(&build_plan)
    );
    assert_eq!(stderr(&build_plan), "");
    assert_eq!(
        stdout(&build_plan),
        format!(
            "typelisp-host-plan v1\n\
             action build-source\n\
             source {}\n\
             output {}\n\
             target windows-x86_64\n\
             backend-mode avx2\n\
             stdlib-root {}\n\
             stdlib-root {}\n\
             end\n",
            host_netstring(source_arg),
            host_netstring(output_arg),
            host_netstring(stdlib_one_arg),
            host_netstring(stdlib_two_arg),
        )
    );

    let run_plan = Command::new(&run_bin)
        .arg(source_arg)
        .arg("--target")
        .arg("linux-x86_64")
        .arg("--backend-mode")
        .arg("avx512")
        .arg("--stdlib-root")
        .arg(stdlib_one_arg)
        .arg("--")
        .arg("arg with spaces")
        .arg("colon:arg")
        .output()
        .expect("run selfhost run planner");
    assert!(
        run_plan.status.success(),
        "selfhost run planner failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&run_plan),
        stderr(&run_plan)
    );
    assert_eq!(stderr(&run_plan), "");
    assert_eq!(
        stdout(&run_plan),
        format!(
            "typelisp-host-plan v1\n\
             action run-source\n\
             source {}\n\
             target linux-x86_64\n\
             backend-mode avx512\n\
             stdlib-root {}\n\
             runtime-arg {}\n\
             runtime-arg {}\n\
             end\n",
            host_netstring(source_arg),
            host_netstring(stdlib_one_arg),
            host_netstring("arg with spaces"),
            host_netstring("colon:arg"),
        )
    );

    let package_build = Command::new(&build_bin)
        .arg("--manifest-path")
        .arg("typelisp.pkg")
        .output()
        .expect("run selfhost build planner package rejection");
    assert!(!package_build.status.success());
    assert_eq!(stdout(&package_build), "");
    assert!(
        stderr(&package_build).contains("--manifest-path is handled by Rust typelisp build"),
        "stderr:\n{}",
        stderr(&package_build)
    );

    let missing_target = Command::new(&run_bin)
        .arg(source_arg)
        .arg("--target")
        .output()
        .expect("run selfhost run planner target failure");
    assert!(!missing_target.status.success());
    assert_eq!(stdout(&missing_target), "");
    assert!(
        stderr(&missing_target).contains("run: --target requires a value"),
        "stderr:\n{}",
        stderr(&missing_target)
    );
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
#[test]
fn selfhost_build_run_planners_default_to_host_target() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let expected_target = if cfg!(target_os = "windows") {
        "windows-x86_64"
    } else {
        "linux-x86_64"
    };

    let build_driver = manifest_dir.join("selfhost").join("build.tl");
    let build_driver_arg = build_driver.to_str().expect("build driver path is utf-8");
    let build_plan = typelisp(&["run", build_driver_arg, "--", "main.tl"]);
    assert!(
        build_plan.status.success(),
        "selfhost build planner default-target probe failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&build_plan),
        stderr(&build_plan)
    );
    assert_eq!(stderr(&build_plan), "");
    let build_stdout = stdout(&build_plan).replace("\r\n", "\n");
    assert!(
        build_stdout.contains(&format!("target {expected_target}\n")),
        "build planner should default to host target {expected_target}\nstdout:\n{}",
        stdout(&build_plan)
    );

    let run_driver = manifest_dir.join("selfhost").join("run.tl");
    let run_driver_arg = run_driver.to_str().expect("run driver path is utf-8");
    let run_plan = typelisp(&["run", run_driver_arg, "--", "main.tl"]);
    assert!(
        run_plan.status.success(),
        "selfhost run planner default-target probe failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&run_plan),
        stderr(&run_plan)
    );
    assert_eq!(stderr(&run_plan), "");
    let run_stdout = stdout(&run_plan).replace("\r\n", "\n");
    assert!(
        run_stdout.contains(&format!("target {expected_target}\n")),
        "run planner should default to host target {expected_target}\nstdout:\n{}",
        stdout(&run_plan)
    );
}

#[cfg(target_os = "linux")]
#[test]
fn run_accepts_backend_mode_flag_with_avx512() {
    let dir = fixture_dir("backend-mode-run-avx512");
    let source = write_main_source(&dir);
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["run", source_arg, "--backend-mode", "avx512", "--", "arg"]);

    assert_eq!(
        stderr(&output),
        "",
        "avx512 run should have no errors for scalar IR"
    );
    assert_eq!(
        output.status.code(),
        Some(42),
        "avx512 run should return program exit code 42"
    );
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
#[test]
fn run_forwards_child_output_and_status() {
    let dir = fixture_dir("run-forward-output");
    let source = dir.join("main.tl");
    fs::write(
        &source,
        r#"(define (main) : i64
  (begin
    (print-string "hello")
    7))
"#,
    )
    .expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");
    let output = typelisp(&["run", source_arg]);

    assert_eq!(
        output.status.code(),
        Some(7),
        "run exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert_eq!(stdout(&output), "hello");
    assert_eq!(stderr(&output), "");
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
#[test]
fn run_stdlib_env_fixture_reads_host_environment() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source = manifest_dir.join("stdlib").join("tests").join("env_api.tl");
    let stdlib_root = manifest_dir.join("stdlib");
    let source_arg = source.to_str().expect("source path is utf-8");
    let stdlib_arg = stdlib_root.to_str().expect("stdlib path is utf-8");
    let path_sep = if cfg!(target_os = "windows") {
        ";"
    } else {
        ":"
    };
    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .args(["run", source_arg, "--stdlib-root", stdlib_arg])
        .env("TYPELISP_STDLIB_TEST_EMPTY", "")
        .env("TYPELISP_STDLIB_TEST_VALUE", "env-value-854")
        .env(
            "TYPELISP_STDLIB_TEST_PATH",
            format!("one{path_sep}two{path_sep}three"),
        )
        .env_remove("TYPELISP_STDLIB_TEST_MISSING_854")
        .output()
        .expect("run stdlib env fixture");

    assert_eq!(
        output.status.code(),
        Some(42),
        "stdlib env fixture exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert_eq!(stdout(&output), "");
    assert_eq!(stderr(&output), "");
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
#[test]
fn run_forwards_stdin_to_child() {
    let dir = fixture_dir("run-forward-stdin");
    let source = dir.join("main.tl");
    fs::write(
        &source,
        r#"(define (main) : unit
  (print-string (read-stdin-line)))
"#,
    )
    .expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");
    let output = typelisp_with_stdin(&["run", source_arg], "hello from stdin\n");

    assert_eq!(
        output.status.code(),
        Some(0),
        "run exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert_eq!(stdout(&output), "hello from stdin");
    assert_eq!(stderr(&output), "");
}

#[test]
fn build_accepts_backend_mode_flag_with_avx512() {
    let dir = fixture_dir("backend-mode-build-avx512");
    let src_dir = dir.join("src");
    fs::create_dir_all(&src_dir).expect("create package src dir");
    fs::write(
        dir.join("typelisp.pkg"),
        r#"(package
  (name "backend_mode_build")
  (version "0.1.0")
  (entry "src/main.tl"))
"#,
    )
    .expect("write package manifest");
    fs::write(src_dir.join("main.tl"), "(define (main) : i64 42)\n").expect("write package source");
    let manifest = dir.join("typelisp.pkg");
    let manifest_arg = manifest.to_str().expect("manifest path is utf-8");

    let output = typelisp(&[
        "build",
        "--manifest-path",
        manifest_arg,
        "--backend-mode",
        "avx512",
    ]);

    assert!(
        output.status.success(),
        "avx512 build should succeed for scalar IR\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
}

#[test]
fn debug_usage_errors_are_specific() {
    let missing = typelisp(&["debug"]);
    assert!(!missing.status.success());
    let missing_stderr = stderr(&missing);
    assert!(missing_stderr.contains("Error: missing debug subcommand"));
    assert!(missing_stderr.contains("typelisp debug tokenize <file.tl>"));

    let unknown = typelisp(&["debug", "wat"]);
    assert!(!unknown.status.success());
    let unknown_stderr = stderr(&unknown);
    assert!(unknown_stderr.contains("Unknown debug command: wat"));
    assert!(unknown_stderr.contains("typelisp debug check <file.tl>"));
}

#[test]
fn check_rejects_unsupported_type_kind_before_backend() {
    let dir = fixture_dir("unsupported-type-kind");
    let source = dir.join("main.tl");
    fs::write(&source, "(define (f [T : type]) : i64 0)\n").expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["check", source_arg]);

    assert!(!output.status.success());
    assert_eq!(stdout(&output), "");
    let stderr = stderr(&output);
    assert!(
        stderr.contains("unsupported type kind 'type'"),
        "stderr:\n{}",
        stderr
    );
    assert!(
        stderr.contains("comptime type values are not implemented yet"),
        "stderr:\n{}",
        stderr
    );
    assert!(
        !stderr.contains("backend:"),
        "type kind should fail before backend validation:\n{}",
        stderr
    );
}

#[test]
fn check_rejects_runtime_use_of_comptime_type_literal_before_backend() {
    let dir = fixture_dir("runtime-type-literal");
    let source = dir.join("main.tl");
    fs::write(&source, "(define (main) : i64 (comptime (type i64)))\n").expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["check", source_arg]);

    assert!(!output.status.success());
    assert_eq!(stdout(&output), "");
    let stderr = stderr(&output);
    assert!(
        stderr.contains("type value i64 is compile-time only"),
        "stderr:\n{}",
        stderr
    );
    assert!(
        !stderr.contains("backend:"),
        "type literal should fail before backend validation:\n{}",
        stderr
    );
}

#[test]
fn check_rejects_region_allocating_builtin_escape() {
    let dir = fixture_dir("region-builtin-escape");
    let source = dir.join("main.tl");
    fs::write(
        &source,
        r#"(define (main) : String
  (with-arena r (int->string 41)))
"#,
    )
    .expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["check", source_arg]);

    assert!(!output.status.success());
    assert_eq!(stdout(&output), "");
    let stderr = stderr(&output);
    assert!(
        stderr.contains("region-tagged value") && stderr.contains("cannot escape with-arena"),
        "stderr:\n{}",
        stderr
    );
    assert!(stderr.contains("error[E0200]"), "stderr:\n{}", stderr);
}

#[test]
fn check_rejects_stdlib_allocating_result_escape_from_nested_region() {
    let dir = fixture_dir("stdlib-region-escape");
    let source = dir.join("main.tl");
    fs::write(
        &source,
        r#"(import "stdlib/string.tl")

(define (main) : String
  (with-arena outer
    (with-arena inner
      (string-trim "  scoped  "))))
"#,
    )
    .expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let stdlib_root = manifest_dir.join("stdlib");
    let stdlib_arg = stdlib_root.to_str().expect("stdlib path is utf-8");

    let output = typelisp(&["check", source_arg, "--stdlib-root", stdlib_arg]);

    assert!(!output.status.success());
    assert_eq!(stdout(&output), "");
    let stderr = stderr(&output);
    assert!(
        stderr.contains("region-tagged value")
            && stderr.contains("cannot escape with-arena 'inner'"),
        "stderr:\n{}",
        stderr
    );
    assert!(stderr.contains("error[E0200]"), "stderr:\n{}", stderr);
}

#[test]
fn check_accepts_stdlib_text_buf_render_used_inside_region() {
    let dir = fixture_dir("stdlib-text-buf-region-scalar");
    let source = dir.join("main.tl");
    fs::write(
        &source,
        r#"(import "stdlib/text_buf.tl")

(define (main) : i64
  (let ([buf : TextBuf (text-buf-append (text-buf-empty) "scoped")])
    (with-arena inner
      (string-length (text-buf-render buf)))))
"#,
    )
    .expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let stdlib_root = manifest_dir.join("stdlib");
    let stdlib_arg = stdlib_root.to_str().expect("stdlib path is utf-8");

    let output = typelisp(&["check", source_arg, "--stdlib-root", stdlib_arg]);

    assert!(
        output.status.success(),
        "text_buf region scalar check failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert_eq!(stdout(&output), "Type checking passed!\n");
    assert_eq!(stderr(&output), "");
}

#[test]
fn check_rejects_stdlib_text_buf_render_escape_from_nested_region() {
    let dir = fixture_dir("stdlib-text-buf-region-escape");
    let source = dir.join("main.tl");
    fs::write(
        &source,
        r#"(import "stdlib/text_buf.tl")

(define (main) : String
  (let ([buf : TextBuf (text-buf-append (text-buf-empty) "scoped")])
    (with-arena outer
      (with-arena inner
        (text-buf-render buf)))))
"#,
    )
    .expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let stdlib_root = manifest_dir.join("stdlib");
    let stdlib_arg = stdlib_root.to_str().expect("stdlib path is utf-8");

    let output = typelisp(&["check", source_arg, "--stdlib-root", stdlib_arg]);

    assert!(!output.status.success());
    assert_eq!(stdout(&output), "");
    let stderr = stderr(&output);
    assert!(
        stderr.contains("region-tagged value")
            && stderr.contains("cannot escape with-arena 'inner'"),
        "stderr:\n{}",
        stderr
    );
    assert!(stderr.contains("error[E0200]"), "stderr:\n{}", stderr);
}

#[test]
fn check_reports_explicit_unsupported_float_cast_diagnostic() {
    let dir = fixture_dir("unsupported-float-cast");
    let source = dir.join("main.tl");
    fs::write(&source, "(define (main) : i64 (cast 3.5 : i64))\n").expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["check", source_arg]);

    assert!(!output.status.success());
    assert_eq!(stdout(&output), "");
    let stderr = stderr(&output);
    assert!(
        stderr.contains("floating-point casts are not supported yet"),
        "stderr:\n{}",
        stderr
    );
    assert!(
        stderr.contains("casts currently support integer/char and f64<->f32 conversions only"),
        "stderr:\n{}",
        stderr
    );
    assert!(stderr.contains("got f64 -> i64"), "stderr:\n{}", stderr);
    assert!(stderr.contains("error[E0200]"), "stderr:\n{}", stderr);
}

#[test]
fn check_warns_for_inexact_contextual_f32_literal() {
    let dir = fixture_dir("inexact-f32-literal-warning");
    let source = dir.join("main.tl");
    fs::write(&source, "(define (main) : f32 0.1)\n").expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["check", source_arg]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "Type checking passed!\n");
    let stderr = stderr(&output);
    assert!(stderr.contains("warning[W0200]"), "stderr:\n{}", stderr);
    assert!(
        stderr.contains("not exactly representable as f32"),
        "stderr:\n{}",
        stderr
    );
}

#[cfg(target_os = "linux")]
#[test]
fn build_source_accepts_avx512_backend_mode() {
    let dir = fixture_dir("backend-mode-source-build-avx512");
    let source = write_main_source(&dir);
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["build", source_arg, "--backend-mode", "avx512"]);

    assert!(
        output.status.success(),
        "avx512 build source should succeed for scalar IR\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
}

#[test]
fn build_source_reports_missing_assembler_with_target_and_tool() {
    let dir = fixture_dir("build-missing-assembler");
    let empty_path = dir.join("empty-path");
    fs::create_dir_all(&empty_path).expect("create empty PATH dir");
    let source = write_main_source(&dir);
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp_with_path(&["build", source_arg], &empty_path);

    assert!(!output.status.success());
    assert_eq!(stdout(&output), "");
    let expected = if cfg!(target_os = "windows") {
        "Error: failed to run assembler 'clang' for target windows-x86_64:"
    } else {
        "Error: failed to run assembler 'as' for target linux-x86_64:"
    };
    assert!(
        stderr(&output).contains(expected),
        "stderr:\n{}",
        stderr(&output)
    );
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
#[test]
fn build_source_default_target_matches_host() {
    let dir = fixture_dir("build-source-default-host-target");
    let source = write_main_source(&dir);
    let source_arg = source.to_str().expect("source path is utf-8");
    let bin_path = if cfg!(target_os = "windows") {
        source.with_extension("exe")
    } else {
        source.with_extension("")
    };

    let output = typelisp(&["build", source_arg]);

    assert!(
        output.status.success(),
        "source build failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert!(
        stdout(&output).contains(&format!("Generated: {}", bin_path.display())),
        "source build stdout should name host executable\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert!(
        bin_path.exists(),
        "source build did not write host executable: {}",
        bin_path.display()
    );

    let run = Command::new(&bin_path)
        .output()
        .expect("run default-target build output");
    assert_eq!(
        run.status.code(),
        Some(42),
        "default-target build output exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&run.stdout),
        String::from_utf8_lossy(&run.stderr)
    );
}

#[test]
fn build_source_missing_output_value_is_error() {
    let dir = fixture_dir("build-missing-output-value");
    let source = dir.join("main.tl");
    fs::write(&source, "(define (main) : i64 42)\n").expect("write source");
    let source_arg = source.to_str().expect("source path is utf-8");

    let output = typelisp(&["build", source_arg, "-o"]);

    assert!(!output.status.success());
    assert!(stderr(&output).contains("build: -o requires a value"));
}

#[test]
fn build_output_without_source_file_is_error() {
    let dir = fixture_dir("build-output-without-source");
    let output_arg = dir
        .join("app")
        .to_str()
        .expect("output path is utf-8")
        .to_string();

    let output = typelisp(&["build", "-o", &output_arg]);

    assert!(!output.status.success());
    assert!(stderr(&output).contains("Error: build -o requires a source file argument"));
}

#[test]
fn build_source_missing_file_reports_module_error() {
    let dir = fixture_dir("build-missing-source");
    let missing_arg = dir
        .join("missing.tl")
        .to_str()
        .expect("missing source path is utf-8")
        .to_string();

    let output = typelisp(&["build", &missing_arg]);

    assert!(!output.status.success());
    assert!(stderr(&output).contains("Error: cannot read module"));
}

#[test]
fn doc_test_checks_module_and_item_examples() {
    let dir = fixture_dir("doc-test-pass");
    let source = dir.join("docs.tl");
    fs::write(
        &source,
        r#";# Module docs.
;# ```typelisp
;# (define (main) : i64 42)
;# ```

;: Item docs.
;: ```tl
;: (define answer : i64 42)
;: ```
(define documented : i64 1)

; Ordinary comments are not docs, so this failing block is ignored.
; ```typelisp
; (define (bad) : i64 true)
; ```
"#,
    )
    .expect("write doctest source");

    let source_arg = source.to_str().expect("source path is utf-8");
    let output = typelisp(&["doc", "--test", source_arg]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "Doc tests passed: 2 example(s)\n");
    assert_doctest_temp_cleaned(&source);
}

#[test]
fn doc_test_accepts_expected_type_errors() {
    let dir = fixture_dir("doc-test-expected-error");
    let source = dir.join("docs.tl");
    fs::write(
        &source,
        r#";;;; Expected error.
;;;; ```typelisp expect-error
;;;; (define (bad) : i64 true)
;;;; ```
"#,
    )
    .expect("write doctest source");

    let source_arg = source.to_str().expect("source path is utf-8");
    let output = typelisp(&["doc", "--test", source_arg]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "Doc tests passed: 1 example(s)\n");
    assert_doctest_temp_cleaned(&source);
}

#[test]
fn doc_test_reports_unexpected_type_errors() {
    let dir = fixture_dir("doc-test-type-error");
    let source = dir.join("docs.tl");
    fs::write(
        &source,
        r#";;;; Unexpected error.
;;;; ```typelisp
;;;; (define (bad) : i64 true)
;;;; ```
"#,
    )
    .expect("write doctest source");

    let source_arg = source.to_str().expect("source path is utf-8");
    let output = typelisp(&["doc", "--test", source_arg]);
    let stderr = stderr(&output);

    assert!(!output.status.success(), "stdout:\n{}", stdout(&output));
    assert!(stderr.contains("doc tests failed"), "stderr:\n{}", stderr);
    assert!(
        stderr.contains("was expected to pass"),
        "stderr:\n{}",
        stderr
    );
    assert!(stderr.contains("error[E0200]"), "stderr:\n{}", stderr);
    assert_doctest_temp_cleaned(&source);
}

#[test]
fn doc_test_reports_malformed_examples() {
    let dir = fixture_dir("doc-test-malformed");
    let source = dir.join("docs.tl");
    fs::write(
        &source,
        r#";;;; Bad fence.
;;;; ```typelisp maybe
;;;; (define (main) : i64 0)
;;;; ```
"#,
    )
    .expect("write doctest source");

    let source_arg = source.to_str().expect("source path is utf-8");
    let output = typelisp(&["doc", "--test", source_arg]);
    let stderr = stderr(&output);

    assert!(!output.status.success(), "stdout:\n{}", stdout(&output));
    assert!(
        stderr.contains("unsupported TypeLisp doctest option `maybe`"),
        "stderr:\n{}",
        stderr
    );
    assert_doctest_temp_cleaned(&source);
}

#[test]
fn doc_test_passes_when_docs_have_no_examples() {
    let dir = fixture_dir("doc-test-empty");
    let source = dir.join("docs.tl");
    fs::write(
        &source,
        r#";;;; Docs without fenced examples.
;;; Item docs without fenced examples.
(define documented : i64 1)
"#,
    )
    .expect("write doctest source");

    let source_arg = source.to_str().expect("source path is utf-8");
    let output = typelisp(&["doc", "--test", source_arg]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "Doc tests passed: 0 example(s)\n");
    assert_doctest_temp_cleaned(&source);
}

#[test]
fn doc_test_uses_stdlib_root_for_imports() {
    let dir = fixture_dir("doc-test-stdlib-root");
    let stdlib_root = dir.join("repo-stdlib");
    fs::create_dir_all(&stdlib_root).expect("create stdlib root");
    fs::write(
        stdlib_root.join("docfixture.tl"),
        "(define stdlib-answer : i64 42)\n",
    )
    .expect("write stdlib fixture");

    let source = dir.join("docs.tl");
    fs::write(
        &source,
        r#";;;; Stdlib import example.
;;;; ```typelisp
;;;; (import "stdlib/docfixture.tl")
;;;; (define (main) : i64 stdlib-answer)
;;;; ```
"#,
    )
    .expect("write doctest source");

    let output = typelisp(&[
        "doc",
        "--test",
        source.to_str().unwrap(),
        "--stdlib-root",
        stdlib_root.to_str().unwrap(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "Doc tests passed: 1 example(s)\n");
    assert_doctest_temp_cleaned(&source);
}

#[test]
#[cfg(any(target_os = "linux", target_os = "windows"))]
fn fmt_formats_source_files_in_place() {
    let dir = fixture_dir("fmt-in-place");
    let first = dir.join("first.tl");
    let second = dir.join("second.tl");
    let source = r#"(define (main [x : i64]) : i64 (begin (print-string "x") x))"#;
    let expected = r#"(define (main [x : i64]) : i64
  (begin
    (print-string "x")
    x))"#;
    fs::write(&first, source).expect("write first source");
    fs::write(&second, source).expect("write second source");

    let output = typelisp(&["fmt", first.to_str().unwrap(), second.to_str().unwrap()]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output), "");
    assert_eq!(stderr(&output), "");
    assert_eq!(
        fs::read_to_string(&first).expect("read first source"),
        expected
    );
    assert_eq!(
        fs::read_to_string(&second).expect("read second source"),
        expected
    );

    let check = typelisp(&["fmt", "--check", first.to_str().unwrap()]);
    assert!(check.status.success(), "stderr:\n{}", stderr(&check));
    assert_eq!(stdout(&check), "");
    assert_eq!(stderr(&check), "");
}

#[test]
#[cfg(any(target_os = "linux", target_os = "windows"))]
fn fmt_check_reports_changes_without_writing() {
    let dir = fixture_dir("fmt-check");
    let source = dir.join("main.tl");
    let original = r#"(define (main [x : i64]) : i64 (begin (print-string "x") x))"#;
    fs::write(&source, original).expect("write source");

    let output = typelisp(&["fmt", "--check", source.to_str().unwrap()]);

    assert!(!output.status.success(), "stdout:\n{}", stdout(&output));
    assert_eq!(stdout(&output), "");
    assert!(
        stderr(&output).contains("fmt: would reformat"),
        "stderr:\n{}",
        stderr(&output)
    );
    assert_eq!(
        fs::read_to_string(&source).expect("read source after check"),
        original
    );
}

#[test]
#[cfg(target_os = "linux")]
fn doc_generates_markdown_for_source_file() {
    let dir = fixture_dir("doc-generate");
    let source = dir.join("simple.tl");
    fs::write(
        &source,
        r#";# Module docs.

;: Item docs.
(define answer : i64 42)
"#,
    )
    .expect("write doc source");

    let source_arg = source.to_str().expect("source path is utf-8");
    let output = typelisp(&["doc", source_arg]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    let expected_md = dir.join("simple.md");
    assert!(expected_md.is_file(), "expected output markdown file");
    let md = fs::read_to_string(&expected_md).expect("read output markdown");
    assert!(
        md.contains("Module docs."),
        "expected module docs in markdown"
    );
    assert!(md.contains("answer"), "expected item name in markdown");
    assert!(
        stdout(&output).contains("Generated:"),
        "expected success message"
    );
}

#[test]
#[cfg(target_os = "linux")]
fn doc_generates_markdown_with_custom_output() {
    let dir = fixture_dir("doc-generate-custom");
    let source = dir.join("input.tl");
    let out = dir.join("custom.md");
    fs::write(
        &source,
        r#";: Single item.
(define x : i64 1)
"#,
    )
    .expect("write doc source");

    let output = typelisp(&["doc", source.to_str().unwrap(), "-o", out.to_str().unwrap()]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert!(out.is_file(), "expected custom output markdown file");
    let md = fs::read_to_string(&out).expect("read output markdown");
    assert!(md.contains("x"), "expected item name in markdown");
}

#[test]
#[cfg(target_os = "linux")]
fn doc_generates_module_graph_navigation() {
    let dir = fixture_dir("doc-module-graph");
    let stdlib_root = dir.join("repo-stdlib");
    fs::create_dir_all(&stdlib_root).expect("create stdlib root");

    let local = dir.join("local.tl");
    fs::write(
        &local,
        r#";;;; Local module docs.

;;; Local answer docs.
(define local-answer : i64 7)
"#,
    )
    .expect("write local doc source");

    let stdlib = stdlib_root.join("docfixture.tl");
    fs::write(
        &stdlib,
        r#";;;; Stdlib module docs.

;;; Stdlib answer docs.
(define stdlib-answer : i64 35)
"#,
    )
    .expect("write stdlib doc source");

    let entry = dir.join("entry.tl");
    fs::write(
        &entry,
        r#";;;; Entry module docs.

(import "local.tl")
(import "local.tl")
(import "stdlib/docfixture.tl")

;;; Entry docs.
(define (main) : i64 (+ local-answer stdlib-answer))
"#,
    )
    .expect("write entry doc source");

    let out = dir.join("graph.md");
    let output = typelisp(&[
        "doc",
        entry.to_str().unwrap(),
        "-o",
        out.to_str().unwrap(),
        "--stdlib-root",
        stdlib_root.to_str().unwrap(),
    ]);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    let md = fs::read_to_string(&out).expect("read generated graph markdown");
    let entry_path = fs::canonicalize(&entry)
        .expect("canonicalize entry")
        .display()
        .to_string();
    let local_path = fs::canonicalize(&local)
        .expect("canonicalize local")
        .display()
        .to_string();
    let stdlib_path = fs::canonicalize(&stdlib)
        .expect("canonicalize stdlib")
        .display()
        .to_string();

    assert!(
        md.contains("## Modules"),
        "expected module navigation:\n{md}"
    );
    assert!(
        md.contains(&format!("- [{entry_path}](#")),
        "expected entry module nav link:\n{md}"
    );
    assert!(
        md.contains(&format!("Source: `{local_path}`")),
        "expected local source path:\n{md}"
    );
    assert!(
        md.contains(&format!("Source: `{stdlib_path}`")),
        "expected stdlib source path:\n{md}"
    );
    assert!(
        md.contains("Entry module docs.")
            && md.contains("Local module docs.")
            && md.contains("Stdlib module docs."),
        "expected docs from entry, local, and stdlib modules:\n{md}"
    );
    assert_eq!(
        md.matches("Local module docs.").count(),
        1,
        "repeated import should not duplicate local docs:\n{md}"
    );

    let entry_idx = md.find(&format!("## {entry_path}")).expect("entry section");
    let local_idx = md.find(&format!("## {local_path}")).expect("local section");
    let stdlib_idx = md
        .find(&format!("## {stdlib_path}"))
        .expect("stdlib section");
    assert!(
        entry_idx < local_idx && local_idx < stdlib_idx,
        "expected stable loader source order:\n{md}"
    );
}

#[test]
fn doc_generate_missing_file_shows_usage() {
    let output = typelisp(&["doc"]);
    assert!(!output.status.success(), "expected failure on missing arg");
    let stderr = stderr(&output);
    assert!(
        stderr.contains("Usage:"),
        "expected usage text in stderr, got:\n{}",
        stderr
    );
    assert!(
        stderr.contains("typelisp doc <file.tl>"),
        "expected doc usage in stderr, got:\n{}",
        stderr
    );
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

// --- debug host-action: private selfhost build/run boundary (#621) ---

fn host_netstring(value: &str) -> String {
    format!("{}:{}", value.len(), value)
}

#[test]
fn host_action_rejects_invalid_plan() {
    let output = typelisp_with_stdin(&["debug", "host-action"], "not a plan\n");
    assert_eq!(
        output.status.code(),
        Some(1),
        "expected failure exit\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert!(
        stderr(&output).contains("invalid host-action plan"),
        "stderr:\n{}",
        stderr(&output)
    );
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
#[test]
fn host_action_build_source_plan_builds_executable_with_spaced_paths() {
    let dir = fixture_dir("host-action-build");
    // A subdirectory whose name contains a space exercises the no-shell-splitting
    // requirement for both the source and the output path.
    let spaced = dir.join("with space");
    fs::create_dir_all(&spaced).expect("create spaced dir");
    let source = spaced.join("main.tl");
    fs::write(&source, "(define (main) : i64 11)\n").expect("write source");
    let output_path = if cfg!(target_os = "windows") {
        spaced.join("the program.exe")
    } else {
        spaced.join("the program")
    };
    let target = if cfg!(target_os = "windows") {
        "windows-x86_64"
    } else {
        "linux-x86_64"
    };

    let plan = format!(
        "typelisp-host-plan v1\n\
         action build-source\n\
         source {}\n\
         output {}\n\
         target {}\n\
         backend-mode scalar\n\
         end\n",
        host_netstring(source.to_str().expect("source path is utf-8")),
        host_netstring(output_path.to_str().expect("output path is utf-8")),
        target,
    );

    let output = typelisp_with_stdin(&["debug", "host-action"], &plan);
    assert_eq!(
        output.status.code(),
        Some(0),
        "host-action build failed\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert!(
        stdout(&output).contains(&format!("Generated: {}", output_path.display())),
        "stdout:\n{}",
        stdout(&output)
    );
    assert!(
        output_path.exists(),
        "built executable missing: {}",
        output_path.display()
    );
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
#[test]
fn host_action_run_source_plan_forwards_output_and_status() {
    let dir = fixture_dir("host-action-run");
    let source = dir.join("main.tl");
    fs::write(
        &source,
        r#"(define (main) : i64
  (begin
    (print-string "from-plan")
    13))
"#,
    )
    .expect("write source");
    let target = if cfg!(target_os = "windows") {
        "windows-x86_64"
    } else {
        "linux-x86_64"
    };

    // The runtime arg contains spaces; the program ignores it, but it must pass
    // through the plan and into the child without being split or rejected.
    let plan = format!(
        "typelisp-host-plan v1\n\
         action run-source\n\
         source {}\n\
         target {}\n\
         backend-mode scalar\n\
         runtime-arg {}\n\
         end\n",
        host_netstring(source.to_str().expect("source path is utf-8")),
        target,
        host_netstring("arg with spaces"),
    );

    let output = typelisp_with_stdin(&["debug", "host-action"], &plan);
    assert_eq!(
        output.status.code(),
        Some(13),
        "host-action run exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert_eq!(stdout(&output), "from-plan");
    assert_eq!(stderr(&output), "");
}

// --- selfhost REPL command driver: piped stdin (#591) ---

// Builds and runs `selfhost/repl.tl` with the given piped stdin. The selfhost
// source tree is copied into a unique per-test fixture dir so imports resolve
// and generated object/executable files do not land in the canonical source dir.
fn run_selfhost_repl(name: &str, stdin: &str) -> Output {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let dir = fixture_dir(name);
    for entry in fs::read_dir(&selfhost_dir).expect("read selfhost dir") {
        let path = entry.expect("read selfhost entry").path();
        if path.extension().and_then(|ext| ext.to_str()) == Some("tl") {
            let file_name = path.file_name().expect("selfhost source has file name");
            fs::copy(&path, dir.join(file_name)).expect("copy selfhost source dependency");
        }
    }
    let source = dir.join("repl.tl");
    let stdlib_root = manifest_dir.join("stdlib");
    let exe = dir.join(if cfg!(target_os = "windows") {
        "repl.exe"
    } else {
        "repl"
    });

    let mut build = Command::new(env!("CARGO_BIN_EXE_typelisp"));
    build
        .arg("build")
        .arg(&source)
        .arg("--stdlib-root")
        .arg(&stdlib_root)
        .arg("-o")
        .arg(&exe);
    if cfg!(target_os = "windows") {
        build.arg("--target").arg("windows-x86_64");
    }
    let build_output = run_with_crash_retry(|| build.output().expect("build selfhost repl"));
    assert!(
        build_output.status.success(),
        "selfhost repl build failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&build_output.stdout),
        String::from_utf8_lossy(&build_output.stderr)
    );

    run_with_crash_retry(|| {
        let mut child = Command::new(&exe)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn selfhost repl");

        child
            .stdin
            .as_mut()
            .expect("stdin is piped")
            .write_all(stdin.as_bytes())
            .expect("write selfhost repl stdin");

        child.wait_with_output().expect("wait for selfhost repl")
    })
}

#[test]
fn selfhost_repl_help_and_exit_from_piped_stdin() {
    let output = run_selfhost_repl("repl-help", ".help\n.exit\n");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "", "stderr:\n{}", stderr(&output));
    let out = stdout(&output);
    assert!(out.contains("TypeLisp REPL commands:"), "stdout:\n{}", out);
    assert!(out.contains(".help"), "stdout:\n{}", out);
    assert!(out.contains(".type <expr>"), "stdout:\n{}", out);
    assert!(out.contains(".exit"), "stdout:\n{}", out);
}

#[test]
fn selfhost_repl_eof_exits_cleanly() {
    // No `.exit`, immediate EOF: the loop ends without error output.
    let output = run_selfhost_repl("repl-eof", "");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "", "stderr:\n{}", stderr(&output));
}

#[test]
fn selfhost_repl_blank_lines_are_skipped() {
    let output = run_selfhost_repl("repl-blank", "\n\n.exit\n");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "", "stderr:\n{}", stderr(&output));
}

#[test]
fn selfhost_repl_unknown_dot_command_reports_and_continues() {
    let output = run_selfhost_repl("repl-unknown", ".wat\n.exit\n");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert!(
        stderr(&output).contains("Unknown REPL command: .wat"),
        "stderr:\n{}",
        stderr(&output)
    );
    assert!(
        stderr(&output).contains("Type .help for commands."),
        "stderr:\n{}",
        stderr(&output)
    );
}

#[test]
fn selfhost_repl_non_command_input_reports_unimplemented() {
    let output = run_selfhost_repl("repl-noncommand", "(+ 1 2)\n.exit\n");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert!(
        stderr(&output).contains("REPL evaluation is not implemented yet"),
        "stderr:\n{}",
        stderr(&output)
    );
}

#[test]
fn selfhost_repl_type_prints_literal_and_session_decl_types() {
    let output = run_selfhost_repl(
        "repl-type",
        ".type 42\n(define answer : i64 41)\n.type (+ answer 1)\n.exit\n",
    );

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "", "stderr:\n{}", stderr(&output));
    let out = stdout(&output);
    assert!(out.contains("i64"), "stdout:\n{}", out);
    assert!(
        out.matches("i64").count() >= 2,
        "stdout should show both inferred i64 results:\n{}",
        out
    );
}

#[test]
fn selfhost_repl_type_rejects_empty_and_declaration_and_continues() {
    let output = run_selfhost_repl(
        "repl-type-errors",
        ".type\n.type (define answer : i64 41)\n.type true\n.exit\n",
    );

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    let err = stderr(&output);
    assert!(
        err.contains("Error: .type expects an expression"),
        "stderr:\n{}",
        err
    );
    assert!(
        err.contains("Error: .type expects an expression, got a declaration"),
        "stderr:\n{}",
        err
    );
    assert!(
        stdout(&output).contains("bool"),
        "stdout:\n{}",
        stdout(&output)
    );
}

// #1270: the selfhost REPL type-check path runs selfhost code as an emitted
// binary that segfaults ~100% on Windows (the same non-ASLR selfhost-driver
// crash as `test --check`/`doc --test`/`check.tl`; distinct from the emitted
// `*_smoke` ASLR crash this PR fixes). Ignore on Windows until #1270 is fixed;
// it still runs on Linux.
#[cfg_attr(
    target_os = "windows",
    ignore = "#1270: selfhost REPL typecheck segfaults on Windows"
)]
#[test]
fn selfhost_repl_type_checks_without_running_code() {
    let output = run_selfhost_repl(
        "repl-type-no-run",
        ".type (begin (print-string \"ran\") 1)\n.exit\n",
    );

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "", "stderr:\n{}", stderr(&output));
    let out = stdout(&output);
    assert!(out.contains("i64"), "stdout:\n{}", out);
    assert!(!out.contains("ran"), "stdout:\n{}", out);
}

#[test]
fn selfhost_repl_multiline_declaration_persists_for_later_declarations() {
    let input = "\
(define (inc [x : i64]) : i64
  (+ x 1))
(define answer : i64 (inc 41))
.type (+ answer 1)
.exit
";
    let output = run_selfhost_repl("repl-session-decls", input);

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert_eq!(stderr(&output), "", "stderr:\n{}", stderr(&output));
    assert!(
        stdout(&output).contains("i64"),
        "stdout:\n{}",
        stdout(&output)
    );
}

#[test]
fn selfhost_repl_parse_and_type_errors_recover_without_mutating_session() {
    let input = "\
(define answer : i64 41)
(define broken : i64 0))
(define bad : i64 true)
(define after : i64 (+ answer 1))
.exit
";
    let output = run_selfhost_repl("repl-error-recover", input);
    let err = stderr(&output);

    assert!(output.status.success(), "stderr:\n{}", err);
    assert!(err.contains("typecheck:"), "stderr:\n{}", err);
    assert!(
        err.contains("parse") || err.contains("unexpected"),
        "stderr:\n{}",
        err
    );
    assert!(
        !err.contains("unknown value: answer"),
        "session declaration was lost after an error:\n{}",
        err
    );
}

#[test]
fn selfhost_repl_eof_during_incomplete_input_reports_diagnostic() {
    let output = run_selfhost_repl("repl-incomplete-eof", "(define (f [x : i64]) : i64\n");

    assert!(output.status.success(), "stderr:\n{}", stderr(&output));
    assert!(
        stderr(&output).contains("incomplete REPL input at EOF"),
        "stderr:\n{}",
        stderr(&output)
    );
}
