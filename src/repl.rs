use crate::ast::{Decl, Expr};
use crate::diagnostic::format_diagnostic;
use crate::lexer::{Lexer, LexerError, Token};
use crate::module::LoadOptions;
use crate::native;
use crate::parser::{ReplItem, parse_repl_item};
use crate::typechecker::TypeChecker;
use crate::types::Type;
use std::collections::BTreeMap;
use std::io::{self, BufRead, IsTerminal, Write};

const BANNER: &str = "TypeLisp REPL. Type .help for commands.\n";
const PROMPT: &str = "tl> ";
const HELP: &str = "\
TypeLisp REPL commands:
  .help         Show this help
  .type <expr>  Print the inferred type without running code
  .exit         Exit the REPL

Top-level declarations are remembered for the rest of the session. A bare
expression is type-checked against the session and run by compiling a scratch
program; its value is printed for i64, bool, f64, char, String, and unit.
";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExitReason {
    Eof,
    ExitCommand,
}

#[derive(Debug, Clone)]
enum ReplInputStatus {
    Empty,
    Incomplete,
    Complete,
    Error(LexerError),
}

fn lexer_error_can_continue(err: &LexerError) -> bool {
    matches!(
        err.msg.as_str(),
        "unterminated string literal" | "unterminated string escape"
    )
}

fn input_status(input: &str) -> ReplInputStatus {
    let mut lexer = Lexer::new(input);
    let mut delimiters = Vec::new();
    let mut saw_token = false;

    loop {
        let token = match lexer.next_token() {
            Ok(token) => token,
            Err(err) if lexer_error_can_continue(&err) => return ReplInputStatus::Incomplete,
            Err(err) => return ReplInputStatus::Error(err),
        };

        match token {
            Token::Eof => break,
            Token::LParen => {
                saw_token = true;
                delimiters.push(Token::LParen);
            }
            Token::LBracket => {
                saw_token = true;
                delimiters.push(Token::LBracket);
            }
            Token::RParen => {
                saw_token = true;
                if delimiters.pop() != Some(Token::LParen) {
                    return ReplInputStatus::Complete;
                }
            }
            Token::RBracket => {
                saw_token = true;
                if delimiters.pop() != Some(Token::LBracket) {
                    return ReplInputStatus::Complete;
                }
            }
            _ => saw_token = true,
        }
    }

    if !saw_token {
        ReplInputStatus::Empty
    } else if delimiters.is_empty() {
        ReplInputStatus::Complete
    } else {
        ReplInputStatus::Incomplete
    }
}

fn handle_complete_input<W: Write, E: Write>(
    input: &str,
    session_decls: &mut Vec<Decl>,
    session_sources: &mut Vec<String>,
    stdout: &mut W,
    stderr: &mut E,
) -> io::Result<()> {
    match parse_repl_item(input) {
        Ok(ReplItem::Decl(decl)) => match TypeChecker::check_repl_decl(session_decls, &decl) {
            // Only mutate the session once the declaration type-checks: keep the
            // AST (for type-checking later items) and its source (for codegen of
            // scratch programs) in lock step.
            Ok(()) => {
                session_decls.push(decl);
                session_sources.push(input.trim().to_string());
            }
            Err(err) => write!(
                stderr,
                "{}",
                format_diagnostic(&err.to_diagnostic(), input, "<repl>")
            )?,
        },
        Ok(ReplItem::Expr(expr)) => {
            evaluate_expr(
                input.trim(),
                &expr,
                session_decls,
                session_sources,
                stdout,
                stderr,
            )?;
        }
        Err(err) => {
            writeln!(stderr, "REPL parse error: {err}")?;
        }
    }
    Ok(())
}

/// Type-check a bare expression against the session, then run it by compiling a
/// scratch program (the accepted declarations plus a generated `main` that
/// prints the result). The expression itself is never persisted.
fn evaluate_expr<W: Write, E: Write>(
    expr_source: &str,
    expr: &Expr,
    session_decls: &[Decl],
    session_sources: &[String],
    stdout: &mut W,
    stderr: &mut E,
) -> io::Result<()> {
    let ty = match TypeChecker::check_repl_expr(session_decls, expr) {
        Ok(ty) => ty,
        Err(err) => {
            return write!(
                stderr,
                "{}",
                format_diagnostic(&err.to_diagnostic(), expr_source, "<repl>")
            );
        }
    };

    let eval_body = match eval_body_for(&ty, expr_source) {
        Some(form) => form,
        None => {
            return writeln!(stderr, "REPL: cannot display a value of type {ty}");
        }
    };

    let program = build_scratch_program(session_sources, &eval_body);
    let options = LoadOptions {
        stdlib_roots: Vec::new(),
        package_roots: BTreeMap::new(),
        embedded_stdlib: true,
    };
    match native::run_scratch_source(&program, &options, &[], native::host_target()) {
        Ok(output) => {
            stdout.write_all(&output.stdout)?;
            stdout.flush()?;
            stderr.write_all(&output.stderr)?;
        }
        Err(err) => writeln!(stderr, "REPL evaluation failed: {}", err.user_message())?,
    }
    Ok(())
}

/// The body that displays `expr_source`'s value, or `None` when the result type
/// has no REPL display form. Value forms yield exactly one trailing newline:
/// `print`/`print-bool`/`print-float` already emit one, while `print-char` and
/// `print-string` do not, so those add `print-newline`. A `unit` expression has
/// no value, so it is run for its effects exactly as written, with no injected
/// output.
fn eval_body_for(ty: &Type, expr_source: &str) -> Option<String> {
    let body = match ty {
        Type::I64 => format!("(print {expr_source})"),
        Type::Bool => format!("(print-bool {expr_source})"),
        Type::F64 => format!("(print-float {expr_source})"),
        Type::Char => format!("(begin (print-char {expr_source}) (print-newline))"),
        Type::String => format!("(begin (print-string {expr_source}) (print-newline))"),
        Type::Unit => expr_source.to_string(),
        _ => return None,
    };
    Some(body)
}

/// Assemble a runnable program from the session's accepted declaration sources
/// and a generated `main` that evaluates `eval_body` and returns 0.
fn build_scratch_program(session_sources: &[String], eval_body: &str) -> String {
    let mut program = String::new();
    for decl in session_sources {
        program.push_str(decl);
        program.push('\n');
    }
    program.push_str("(define (main) : i64\n  (begin\n    ");
    program.push_str(eval_body);
    program.push_str("\n    0))\n");
    program
}

pub fn run_stdio() -> io::Result<ExitReason> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let stderr = io::stderr();
    let interactive = stdin.is_terminal();

    run(stdin.lock(), stdout.lock(), stderr.lock(), interactive)
}

pub fn run<R, W, E>(
    mut reader: R,
    mut stdout: W,
    mut stderr: E,
    interactive: bool,
) -> io::Result<ExitReason>
where
    R: BufRead,
    W: Write,
    E: Write,
{
    if interactive {
        stdout.write_all(BANNER.as_bytes())?;
    }

    let mut session_decls = Vec::new();
    let mut session_sources: Vec<String> = Vec::new();
    let mut line = String::new();
    let mut pending = String::new();
    loop {
        if interactive {
            stdout.write_all(PROMPT.as_bytes())?;
            stdout.flush()?;
        }

        line.clear();
        let bytes = reader.read_line(&mut line)?;
        if bytes == 0 {
            if !pending.trim().is_empty()
                && matches!(input_status(&pending), ReplInputStatus::Incomplete)
            {
                writeln!(stderr, "Error: incomplete REPL input at EOF")?;
            }
            return Ok(ExitReason::Eof);
        }

        if pending.is_empty() {
            let input = line.trim();
            if input.is_empty() {
                continue;
            }

            if let Some(expr_source) = type_command_expr(input) {
                handle_type_command(expr_source, &session_decls, &mut stdout, &mut stderr)?;
                continue;
            }

            match input {
                ".exit" => return Ok(ExitReason::ExitCommand),
                ".help" => {
                    stdout.write_all(HELP.as_bytes())?;
                    continue;
                }
                command if command.starts_with('.') => {
                    writeln!(stderr, "Unknown REPL command: {command}")?;
                    writeln!(stderr, "Type .help for commands.")?;
                    continue;
                }
                _ => {}
            }
        }

        pending.push_str(&line);
        match input_status(&pending) {
            ReplInputStatus::Empty => pending.clear(),
            ReplInputStatus::Incomplete => {}
            ReplInputStatus::Complete => {
                handle_complete_input(
                    &pending,
                    &mut session_decls,
                    &mut session_sources,
                    &mut stdout,
                    &mut stderr,
                )?;
                pending.clear();
            }
            ReplInputStatus::Error(err) => {
                writeln!(stderr, "REPL input error: {err}")?;
                pending.clear();
            }
        }
    }
}

fn type_command_expr(input: &str) -> Option<&str> {
    let rest = input.strip_prefix(".type")?;
    match rest.chars().next() {
        None => Some(""),
        Some(ch) if ch.is_whitespace() => Some(rest.trim_start()),
        _ => None,
    }
}

fn handle_type_command<W, E>(
    source: &str,
    session_decls: &[Decl],
    stdout: &mut W,
    stderr: &mut E,
) -> io::Result<()>
where
    W: Write,
    E: Write,
{
    if source.is_empty() {
        writeln!(stderr, "Error: .type expects an expression")?;
        return Ok(());
    }

    match parse_repl_item(source) {
        Ok(ReplItem::Expr(expr)) => match TypeChecker::check_repl_expr(session_decls, &expr) {
            Ok(ty) => writeln!(stdout, "{ty}")?,
            Err(err) => write!(
                stderr,
                "{}",
                format_diagnostic(&err.to_diagnostic(), source, "<repl>")
            )?,
        },
        Ok(ReplItem::Decl(_)) => {
            writeln!(
                stderr,
                "Error: .type expects an expression, got a declaration"
            )?;
        }
        Err(err) => write!(
            stderr,
            "{}",
            format_diagnostic(&err.to_diagnostic(), source, "<repl>")
        )?,
    }

    Ok(())
}
