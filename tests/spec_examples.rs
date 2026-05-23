use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

#[derive(Debug)]
struct Example {
    name: String,
    line: usize,
    source: String,
    mode: Mode,
}

#[derive(Debug)]
enum Mode {
    Check,
    Compile,
    Run { exit_code: i32, stdout: String },
    Ignore { reason: String },
}

#[test]
fn spec_lisp_examples_follow_test_metadata() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let spec_path = manifest_dir.join("SPEC.md");
    let spec = fs::read_to_string(&spec_path).expect("read SPEC.md");
    let examples = parse_spec_examples(&spec);

    assert!(
        !examples.is_empty(),
        "SPEC.md should contain metadata-bearing lisp examples",
    );

    let work_dir = manifest_dir.join("target").join("spec-example-tests");
    fs::create_dir_all(&work_dir).expect("create spec example test work dir");

    for example in examples {
        match &example.mode {
            Mode::Ignore { reason } => {
                assert!(
                    !reason.trim().is_empty(),
                    "SPEC.md:{} example '{}' has an empty ignore reason",
                    example.line,
                    example.name,
                );
            }
            Mode::Check => {
                let source_path = write_example(&work_dir, &example);
                let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
                    .arg("check")
                    .arg(&source_path)
                    .output()
                    .unwrap_or_else(|err| {
                        panic!(
                            "SPEC.md:{} example '{}' failed to spawn typelisp check: {}",
                            example.line, example.name, err
                        )
                    });
                assert_success("check", &example, &output);
            }
            Mode::Compile => {
                let source_path = write_example(&work_dir, &example);
                let asm_path = work_dir.join(format!("{}.s", example.name));
                let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
                    .arg("compile")
                    .arg(&source_path)
                    .arg("-o")
                    .arg(&asm_path)
                    .output()
                    .unwrap_or_else(|err| {
                        panic!(
                            "SPEC.md:{} example '{}' failed to spawn typelisp compile: {}",
                            example.line, example.name, err
                        )
                    });
                assert_success("compile", &example, &output);
            }
            Mode::Run { exit_code, stdout } => {
                if cfg!(target_os = "linux") {
                    let source_path = write_example(&work_dir, &example);
                    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
                        .arg("run")
                        .arg(&source_path)
                        .output()
                        .unwrap_or_else(|err| {
                            panic!(
                                "SPEC.md:{} example '{}' failed to spawn typelisp run: {}",
                                example.line, example.name, err
                            )
                        });

                    let actual_stdout = String::from_utf8_lossy(&output.stdout);
                    let actual_stderr = String::from_utf8_lossy(&output.stderr);
                    assert_eq!(
                        output.status.code(),
                        Some(*exit_code),
                        "SPEC.md:{} example '{}' had wrong exit code\nstdout:\n{}\nstderr:\n{}",
                        example.line,
                        example.name,
                        actual_stdout,
                        actual_stderr,
                    );
                    assert_eq!(
                        actual_stdout, *stdout,
                        "SPEC.md:{} example '{}' had wrong stdout\nstderr:\n{}",
                        example.line, example.name, actual_stderr,
                    );
                }
            }
        }
    }
}

fn parse_spec_examples(spec: &str) -> Vec<Example> {
    let mut examples = Vec::new();
    let mut names = HashSet::new();
    let mut active: Option<ActiveFence> = None;

    for (line_index, line) in spec.lines().enumerate() {
        let line_number = line_index + 1;
        let trimmed = line.trim_start();

        if let Some(fence) = active.as_mut() {
            if trimmed.starts_with("```") {
                if let Some(metadata) = fence.metadata.take() {
                    let example = build_example(
                        fence.opening_line,
                        metadata,
                        std::mem::take(&mut fence.source),
                    );
                    if !names.insert(example.name.clone()) {
                        panic!(
                            "SPEC.md:{} example '{}' duplicates a previous name",
                            example.line, example.name
                        );
                    }
                    examples.push(example);
                }
                active = None;
            } else if fence.metadata.is_some() {
                fence.source.push_str(line);
                fence.source.push('\n');
            }
            continue;
        }

        if let Some(info) = trimmed.strip_prefix("```") {
            let info = info.trim();
            let metadata = lisp_metadata(info).map(|metadata_text| {
                if metadata_text.trim().is_empty() {
                    panic!(
                        "SPEC.md:{} lisp fence is missing test= metadata",
                        line_number
                    );
                }
                parse_metadata(line_number, metadata_text)
            });
            active = Some(ActiveFence {
                opening_line: line_number,
                metadata,
                source: String::new(),
            });
        }
    }

    if let Some(fence) = active {
        panic!(
            "SPEC.md:{} has an unclosed Markdown fence",
            fence.opening_line
        );
    }

    examples
}

struct ActiveFence {
    opening_line: usize,
    metadata: Option<HashMap<String, String>>,
    source: String,
}

fn lisp_metadata(info: &str) -> Option<&str> {
    if info == "lisp" {
        return Some("");
    }

    if let Some(rest) = info.strip_prefix("lisp") {
        if rest.starts_with(char::is_whitespace) {
            return Some(rest.trim_start());
        }
    }

    None
}

fn build_example(line: usize, mut metadata: HashMap<String, String>, source: String) -> Example {
    let mode_text = take_required(&mut metadata, line, None, "test");
    let name = take_required(&mut metadata, line, Some(&mode_text), "name");
    validate_name(line, &name);

    let mode = match mode_text.as_str() {
        "check" => {
            reject_remaining(&metadata, line, &name);
            Mode::Check
        }
        "compile" => {
            reject_remaining(&metadata, line, &name);
            Mode::Compile
        }
        "run" => {
            let exit_code_text = take_required(&mut metadata, line, Some(&name), "exit");
            let exit_code = exit_code_text.parse::<i32>().unwrap_or_else(|err| {
                panic!(
                    "SPEC.md:{} example '{}' has invalid exit code '{}': {}",
                    line, name, exit_code_text, err
                )
            });
            let stdout = take_required(&mut metadata, line, Some(&name), "stdout");
            reject_remaining(&metadata, line, &name);
            Mode::Run { exit_code, stdout }
        }
        "ignore" => {
            let reason = take_required(&mut metadata, line, Some(&name), "reason");
            reject_remaining(&metadata, line, &name);
            Mode::Ignore { reason }
        }
        other => {
            panic!(
                "SPEC.md:{} example '{}' has unknown test mode '{}'",
                line, name, other
            );
        }
    };

    Example {
        name,
        line,
        source,
        mode,
    }
}

fn take_required(
    metadata: &mut HashMap<String, String>,
    line: usize,
    example: Option<&str>,
    key: &str,
) -> String {
    metadata.remove(key).unwrap_or_else(|| match example {
        Some(name) => panic!(
            "SPEC.md:{} example '{}' is missing required metadata '{}'",
            line, name, key
        ),
        None => panic!("SPEC.md:{} lisp fence is missing metadata '{}'", line, key),
    })
}

fn reject_remaining(metadata: &HashMap<String, String>, line: usize, name: &str) {
    if let Some(key) = metadata.keys().next() {
        panic!(
            "SPEC.md:{} example '{}' has unsupported metadata key '{}'",
            line, name, key
        );
    }
}

fn validate_name(line: usize, name: &str) {
    assert!(
        !name.is_empty(),
        "SPEC.md:{} example name must not be empty",
        line,
    );
    assert!(
        name.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'),
        "SPEC.md:{} example '{}' must use only ASCII letters, digits, '-' or '_'",
        line,
        name,
    );
}

fn parse_metadata(line: usize, text: &str) -> HashMap<String, String> {
    let chars: Vec<char> = text.chars().collect();
    let mut metadata = HashMap::new();
    let mut index = 0;

    while index < chars.len() {
        while index < chars.len() && chars[index].is_whitespace() {
            index += 1;
        }
        if index >= chars.len() {
            break;
        }

        let key_start = index;
        while index < chars.len() && is_key_char(chars[index]) {
            index += 1;
        }
        if key_start == index {
            panic!(
                "SPEC.md:{} has malformed metadata near '{}'",
                line,
                chars[index..].iter().collect::<String>()
            );
        }
        let key = chars[key_start..index].iter().collect::<String>();
        if index >= chars.len() || chars[index] != '=' {
            panic!(
                "SPEC.md:{} metadata key '{}' must be followed by '='",
                line, key
            );
        }
        index += 1;

        let value = if index < chars.len() && chars[index] == '"' {
            index += 1;
            let mut value = String::new();
            let mut closed = false;
            while index < chars.len() {
                match chars[index] {
                    '"' => {
                        index += 1;
                        closed = true;
                        break;
                    }
                    '\\' => {
                        index += 1;
                        if index >= chars.len() {
                            panic!("SPEC.md:{} has a trailing escape in metadata", line);
                        }
                        let escaped = match chars[index] {
                            'n' => '\n',
                            'r' => '\r',
                            't' => '\t',
                            '"' => '"',
                            '\\' => '\\',
                            other => {
                                panic!(
                                    "SPEC.md:{} has unsupported metadata escape '\\{}'",
                                    line, other
                                );
                            }
                        };
                        value.push(escaped);
                        index += 1;
                    }
                    c => {
                        value.push(c);
                        index += 1;
                    }
                }
            }
            if !closed {
                panic!("SPEC.md:{} has an unterminated quoted metadata value", line);
            }
            value
        } else {
            let value_start = index;
            while index < chars.len() && !chars[index].is_whitespace() {
                index += 1;
            }
            if value_start == index {
                panic!("SPEC.md:{} metadata key '{}' has no value", line, key);
            }
            chars[value_start..index].iter().collect()
        };

        if metadata.insert(key.clone(), value).is_some() {
            panic!("SPEC.md:{} has duplicate metadata key '{}'", line, key);
        }
    }

    metadata
}

fn is_key_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '-' || c == '_'
}

fn write_example(work_dir: &Path, example: &Example) -> PathBuf {
    let source_path = work_dir.join(format!("{}.tl", example.name));
    fs::write(&source_path, &example.source).unwrap_or_else(|err| {
        panic!(
            "SPEC.md:{} example '{}' could not be written to {}: {}",
            example.line,
            example.name,
            source_path.display(),
            err
        )
    });
    source_path
}

fn assert_success(command: &str, example: &Example, output: &Output) {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "SPEC.md:{} example '{}' failed typelisp {}\nstdout:\n{}\nstderr:\n{}",
        example.line,
        example.name,
        command,
        stdout,
        stderr,
    );
}
