use std::io::{self, BufRead, IsTerminal, Write};

const BANNER: &str = "TypeLisp REPL. Type .help for commands.\n";
const PROMPT: &str = "tl> ";
const HELP: &str = "\
TypeLisp REPL commands:
  .help  Show this help
  .exit  Exit the REPL
";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExitReason {
    Eof,
    ExitCommand,
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

    let mut line = String::new();
    loop {
        if interactive {
            stdout.write_all(PROMPT.as_bytes())?;
            stdout.flush()?;
        }

        line.clear();
        let bytes = reader.read_line(&mut line)?;
        if bytes == 0 {
            return Ok(ExitReason::Eof);
        }

        let input = line.trim();
        if input.is_empty() {
            continue;
        }

        match input {
            ".exit" => return Ok(ExitReason::ExitCommand),
            ".help" => stdout.write_all(HELP.as_bytes())?,
            command if command.starts_with('.') => {
                writeln!(stderr, "Unknown REPL command: {command}")?;
                writeln!(stderr, "Type .help for commands.")?;
            }
            _ => {
                writeln!(
                    stderr,
                    "REPL evaluation is not implemented yet. Type .help for commands."
                )?;
            }
        }
    }
}
