use crate::diagnostic::{Diagnostic, format_diagnostic};
use crate::module::{
    FsSource, LoadError, LoadOptions, SourceFile, load_program, load_program_with_options,
};
use crate::typechecker::TypeChecker;
use std::fmt::Write as _;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Expectation {
    Pass,
    Error,
}

#[derive(Debug, Clone)]
struct DocLine {
    line_number: usize,
    text: String,
}

#[derive(Debug, Clone)]
struct DocExample {
    index: usize,
    source_line: usize,
    expectation: Expectation,
    code: String,
}

#[derive(Debug, Clone)]
struct DocExampleError {
    line_number: usize,
    message: String,
}

#[derive(Debug)]
pub struct DocTestReport {
    pub total: usize,
}

#[derive(Debug)]
pub struct DocTestFailureReport {
    pub total: usize,
    pub failures: Vec<String>,
}

impl std::fmt::Display for DocTestFailureReport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        writeln!(
            f,
            "doc tests failed: {} failure(s) across {} example(s)",
            self.failures.len(),
            self.total
        )?;
        for failure in &self.failures {
            writeln!(f)?;
            writeln!(f, "{}", failure)?;
        }
        Ok(())
    }
}

pub fn run_doc_tests(
    path: &Path,
    options: &LoadOptions,
) -> Result<DocTestReport, DocTestFailureReport> {
    let source = fs::read_to_string(path).map_err(|err| DocTestFailureReport {
        total: 0,
        failures: vec![format!(
            "cannot read doctest source '{}': {}",
            path.display(),
            err
        )],
    })?;

    let mut examples = Vec::new();
    let mut malformed = Vec::new();
    extract_doc_examples(&source, &mut examples, &mut malformed);

    if !malformed.is_empty() {
        return Err(DocTestFailureReport {
            total: examples.len(),
            failures: malformed
                .into_iter()
                .map(|err| format!("{}:{}: {}", path.display(), err.line_number, err.message))
                .collect(),
        });
    }

    let temp_parent = doctest_temp_parent(path);
    let temp_root = temp_parent.join(doctest_temp_leaf(path));
    let mut failures = Vec::new();

    if let Err(err) = reset_temp_root(&temp_root) {
        return Err(DocTestFailureReport {
            total: examples.len(),
            failures: vec![format!(
                "cannot prepare doctest temp directory '{}': {}",
                temp_root.display(),
                err
            )],
        });
    }

    for example in &examples {
        let example_path = temp_root.join(format!("example_{:03}.tl", example.index));
        if let Err(err) = fs::write(&example_path, &example.code) {
            failures.push(format!(
                "{}:{}: cannot write doctest example {} to '{}': {}",
                path.display(),
                example.source_line,
                example.index,
                example_path.display(),
                err
            ));
            continue;
        }

        let result = check_example(&example_path, options);
        match (example.expectation, result) {
            (Expectation::Pass, Ok(())) => {}
            (Expectation::Pass, Err(diag)) => failures.push(format!(
                "{}:{}: doctest example {} was expected to pass\n{}",
                path.display(),
                example.source_line,
                example.index,
                diag.trim_end()
            )),
            (Expectation::Error, Ok(())) => failures.push(format!(
                "{}:{}: doctest example {} was expected to fail but passed",
                path.display(),
                example.source_line,
                example.index
            )),
            (Expectation::Error, Err(_)) => {}
        }
    }

    if let Err(err) = fs::remove_dir_all(&temp_root) {
        failures.push(format!(
            "cannot clean doctest temp directory '{}': {}",
            temp_root.display(),
            err
        ));
    }
    match fs::remove_dir(&temp_parent) {
        Ok(()) => {}
        Err(err) if err.kind() == io::ErrorKind::NotFound => {}
        Err(err) if err.kind() == io::ErrorKind::DirectoryNotEmpty => {}
        Err(err) => failures.push(format!(
            "cannot clean doctest temp parent '{}': {}",
            temp_parent.display(),
            err
        )),
    }

    if failures.is_empty() {
        Ok(DocTestReport {
            total: examples.len(),
        })
    } else {
        Err(DocTestFailureReport {
            total: examples.len(),
            failures,
        })
    }
}

fn reset_temp_root(temp_root: &Path) -> io::Result<()> {
    match fs::remove_dir_all(temp_root) {
        Ok(()) => {}
        Err(err) if err.kind() == io::ErrorKind::NotFound => {}
        Err(err) => return Err(err),
    }
    fs::create_dir_all(temp_root)
}

fn check_example(path: &Path, options: &LoadOptions) -> Result<(), String> {
    let loaded = if options.stdlib_roots.is_empty() && options.package_roots.is_empty() {
        load_program(path, &FsSource)
    } else {
        load_program_with_options(path, &FsSource, options)
    }
    .map_err(format_load_error)?;

    let mut checker = TypeChecker::new();
    checker
        .check_program(&loaded.program)
        .map_err(|err| format_diagnostic_from_sources(&err.to_diagnostic(), &loaded.sources))?;
    Ok(())
}

fn format_load_error(err: LoadError) -> String {
    match err {
        LoadError::Parse {
            path,
            source_text,
            error,
        } => format_diagnostic(
            &error.to_diagnostic(),
            &source_text,
            &path.display().to_string(),
        ),
        other => format!("Error: {}", other),
    }
}

fn format_diagnostic_from_sources(diag: &Diagnostic, sources: &[SourceFile]) -> String {
    let source = sources
        .iter()
        .find(|s| s.id == diag.span.file_id)
        .or_else(|| sources.first());

    match source {
        Some(source) => format_diagnostic(
            diag,
            &source.source_text,
            &source.path.display().to_string(),
        ),
        None => format_diagnostic(diag, "", "<unknown>"),
    }
}

fn doctest_temp_parent(path: &Path) -> PathBuf {
    path.parent()
        .unwrap_or_else(|| Path::new("."))
        .join(".typelisp-doctest")
}

fn doctest_temp_leaf(path: &Path) -> String {
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .map(sanitize_for_path)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "source".to_string());
    let display = path.to_string_lossy();
    format!("{}-{:016x}", stem, stable_hash(display.as_bytes()))
}

fn sanitize_for_path(input: &str) -> String {
    input
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .collect()
}

fn stable_hash(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in bytes {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn extract_doc_examples(
    source: &str,
    examples: &mut Vec<DocExample>,
    malformed: &mut Vec<DocExampleError>,
) {
    let mut module_docs = Vec::new();
    let mut pending_item_docs = Vec::new();

    for (idx, line) in source.lines().enumerate() {
        let line_number = idx + 1;
        if let Some(text) = doc_comment_body(line, ";;;;") {
            pending_item_docs.clear();
            module_docs.push(DocLine { line_number, text });
            continue;
        }

        scan_doc_block(&module_docs, examples, malformed);
        module_docs.clear();

        if let Some(text) = doc_comment_body(line, ";;;") {
            pending_item_docs.push(DocLine { line_number, text });
            continue;
        }

        let trimmed = line.trim_start();
        if pending_item_docs.is_empty() {
            continue;
        }
        if supported_item_declaration(trimmed) {
            scan_doc_block(&pending_item_docs, examples, malformed);
        }
        pending_item_docs.clear();
    }

    scan_doc_block(&module_docs, examples, malformed);
}

fn doc_comment_body(line: &str, prefix: &str) -> Option<String> {
    let trimmed = line.trim_start();
    if !trimmed.starts_with(prefix) {
        return None;
    }
    if prefix == ";;;" && trimmed.starts_with(";;;;") {
        return None;
    }
    let body = &trimmed[prefix.len()..];
    Some(body.strip_prefix(' ').unwrap_or(body).to_string())
}

fn supported_item_declaration(trimmed: &str) -> bool {
    let Some(rest) = trimmed.strip_prefix('(') else {
        return false;
    };
    let rest = rest.trim_start();
    starts_with_form_head(rest, "define")
        || starts_with_form_head(rest, "extern")
        || starts_with_form_head(rest, "defenum")
        || starts_with_form_head(rest, "defstruct")
}

fn starts_with_form_head(text: &str, head: &str) -> bool {
    let Some(rest) = text.strip_prefix(head) else {
        return false;
    };
    rest.is_empty()
        || rest
            .chars()
            .next()
            .is_some_and(|ch| ch.is_ascii_whitespace() || ch == '(' || ch == ')')
}

fn scan_doc_block(
    lines: &[DocLine],
    examples: &mut Vec<DocExample>,
    malformed: &mut Vec<DocExampleError>,
) {
    let mut i = 0;
    while i < lines.len() {
        let line = &lines[i];
        let trimmed = line.text.trim_start();
        let Some(info) = trimmed.strip_prefix("```") else {
            i += 1;
            continue;
        };

        match parse_fence_info(info, line.line_number) {
            FenceInfo::Ignore => {
                i += 1;
                while i < lines.len() && !lines[i].text.trim_start().starts_with("```") {
                    i += 1;
                }
                if i < lines.len() {
                    i += 1;
                }
            }
            FenceInfo::Malformed(err) => {
                malformed.push(err);
                i += 1;
            }
            FenceInfo::TypeLisp(expectation) => {
                let start_line = line.line_number;
                i += 1;
                let mut code = String::new();
                let mut closed = false;
                while i < lines.len() {
                    let body_line = &lines[i];
                    if body_line.text.trim_start().starts_with("```") {
                        closed = true;
                        i += 1;
                        break;
                    }
                    writeln!(&mut code, "{}", body_line.text).expect("write to string");
                    i += 1;
                }

                if !closed {
                    malformed.push(DocExampleError {
                        line_number: start_line,
                        message: "unterminated TypeLisp doctest fence".to_string(),
                    });
                } else if code.trim().is_empty() {
                    malformed.push(DocExampleError {
                        line_number: start_line,
                        message: "empty TypeLisp doctest fence".to_string(),
                    });
                } else {
                    examples.push(DocExample {
                        index: examples.len() + 1,
                        source_line: start_line,
                        expectation,
                        code,
                    });
                }
            }
        }
    }
}

enum FenceInfo {
    Ignore,
    TypeLisp(Expectation),
    Malformed(DocExampleError),
}

fn parse_fence_info(info: &str, line_number: usize) -> FenceInfo {
    let mut parts = info.split_whitespace();
    let Some(language) = parts.next() else {
        return FenceInfo::Ignore;
    };
    if language != "typelisp" && language != "tl" {
        return FenceInfo::Ignore;
    }

    let mut expectation = Expectation::Pass;
    for option in parts {
        match option {
            "expect-error" => expectation = Expectation::Error,
            other => {
                return FenceInfo::Malformed(DocExampleError {
                    line_number,
                    message: format!("unsupported TypeLisp doctest option `{}`", other),
                });
            }
        }
    }
    FenceInfo::TypeLisp(expectation)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn examples(source: &str) -> Result<Vec<DocExample>, Vec<DocExampleError>> {
        let mut examples = Vec::new();
        let mut errors = Vec::new();
        extract_doc_examples(source, &mut examples, &mut errors);
        if errors.is_empty() {
            Ok(examples)
        } else {
            Err(errors)
        }
    }

    #[test]
    fn extracts_module_and_attached_item_doctests() {
        let extracted = examples(
            r#";;;; Module docs
;;;; ```typelisp
;;;; (define (main) : i64 0)
;;;; ```

;;; Item docs
;;; ```tl expect-error
;;; (define (bad) : i64 true)
;;; ```
(define good : i64 1)

;;; Unattached docs are ignored
"#,
        )
        .expect("extract examples");

        assert_eq!(extracted.len(), 2);
        assert_eq!(extracted[0].source_line, 2);
        assert_eq!(extracted[0].expectation, Expectation::Pass);
        assert!(extracted[0].code.contains("(define (main)"));
        assert_eq!(extracted[1].source_line, 7);
        assert_eq!(extracted[1].expectation, Expectation::Error);
        assert!(extracted[1].code.contains("(define (bad)"));
    }

    #[test]
    fn ordinary_comments_do_not_create_doctests() {
        let extracted = examples(
            r#"; ```typelisp
; (define (bad) : i64 true)
; ```
;; ```typelisp
;; (define (also-bad) : i64 true)
;; ```
"#,
        )
        .expect("extract examples");

        assert!(extracted.is_empty());
    }

    #[test]
    fn malformed_typelisp_fence_is_reported() {
        let errors = examples(
            r#";;;; ```typelisp maybe
;;;; (define (main) : i64 0)
;;;; ```
"#,
        )
        .expect_err("malformed fence should fail");

        assert_eq!(errors.len(), 1);
        assert_eq!(errors[0].line_number, 1);
        assert!(
            errors[0]
                .message
                .contains("unsupported TypeLisp doctest option")
        );
    }
}
