use crate::ast::Decl;
use crate::diagnostic::format_diagnostic;
use crate::lexer::{Lexer, LexerError, Token};
use crate::parser::{ReplItem, parse_repl_item};
use crate::typechecker::TypeChecker;
use std::io::{self, BufRead, IsTerminal, Write};

const BANNER: &str = "TypeLisp REPL. Type .help for commands.\n";
const PROMPT: &str = "tl> ";
const HELP: &str = "\
TypeLisp REPL commands:
  .help         Show this help
  .type <expr>  Print the inferred type without running code
  .exit         Exit the REPL

Top-level declarations are remembered for later .type commands.
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

fn handle_complete_input<E: Write>(
    input: &str,
    session_decls: &mut Vec<Decl>,
    stderr: &mut E,
) -> io::Result<()> {
    match parse_repl_item(input) {
        Ok(ReplItem::Decl(decl)) => match TypeChecker::check_repl_decl(session_decls, &decl) {
            Ok(()) => session_decls.push(decl),
            Err(err) => write!(
                stderr,
                "{}",
                format_diagnostic(&err.to_diagnostic(), input, "<repl>")
            )?,
        },
        Ok(ReplItem::Expr(_)) => {
            writeln!(
                stderr,
                "REPL evaluation is not implemented yet. Type .help for commands."
            )?;
        }
        Err(err) => {
            writeln!(stderr, "REPL parse error: {err}")?;
        }
    }
    Ok(())
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
                handle_complete_input(&pending, &mut session_decls, &mut stderr)?;
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
