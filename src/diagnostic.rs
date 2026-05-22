use crate::span::Span;
use std::fmt;

/// A diagnostic error with a source location.
#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub level: Level,
    pub message: String,
    pub span: Span,
    pub code: Option<String>,
    pub help: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Error,
    Warning,
    Note,
}

impl Diagnostic {
    pub fn new(level: Level, message: impl Into<String>, span: Span) -> Self {
        Diagnostic {
            level,
            message: message.into(),
            span,
            code: None,
            help: None,
        }
    }

    pub fn error(message: impl Into<String>, span: Span) -> Self {
        Self::new(Level::Error, message, span)
    }

    pub fn with_code(mut self, code: impl Into<String>) -> Self {
        self.code = Some(code.into());
        self
    }

    pub fn with_help(mut self, help: impl Into<String>) -> Self {
        self.help = Some(help.into());
        self
    }
}

/// Render diagnostics to a string given the source text.
pub fn format_diagnostic(diag: &Diagnostic, source: &str, file: &str) -> String {
    let mut out = String::new();

    // Header: error[E0001]: message
    let level_str = match diag.level {
        Level::Error => "error",
        Level::Warning => "warning",
        Level::Note => "note",
    };
    match &diag.code {
        Some(code) => out.push_str(&format!("{}[{}]: {}\n", level_str, code, diag.message)),
        None => out.push_str(&format!("{}: {}\n", level_str, diag.message)),
    }

    // Location:   --> file:line:col
    out.push_str(&format!(
        "  --> {}:{}:{}\n",
        file, diag.span.start_line, diag.span.start_col
    ));

    // Separator line
    out.push_str("   |\n");

    // Source snippet and underline
    let lines: Vec<&str> = source.lines().collect();
    let line_idx = diag.span.start_line.saturating_sub(1);
    let end_line_idx = diag.span.end_line.saturating_sub(1);

    if line_idx < lines.len() {
        let line_num = diag.span.start_line;
        let line_text = lines[line_idx];
        let gutter = format!("{}", line_num);
        // Pad gutter to 2 chars min
        out.push_str(&format!("{:>2} | {}\n", gutter, line_text));

        // Underline
        let start_col = diag.span.start_col.saturating_sub(1);
        let mut end_col = if line_idx == end_line_idx {
            diag.span.end_col.saturating_sub(1)
        } else {
            line_text.len()
        };
        if end_col < start_col {
            end_col = start_col;
        }

        let spaces = start_col;
        let underline_len = end_col.saturating_sub(start_col).max(1);
        out.push_str(&format!(
            "{:>2} | {}{}\n",
            "",
            " ".repeat(spaces),
            "^".repeat(underline_len)
        ));
    }

    // Help message
    if let Some(help) = &diag.help {
        out.push_str(&format!("   = help: {}\n", help));
    }

    out
}

impl fmt::Display for Diagnostic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {} at {}:{}",
            match self.level {
                Level::Error => "error",
                Level::Warning => "warning",
                Level::Note => "note",
            },
            self.message,
            self.span.start_line,
            self.span.start_col,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_simple() {
        // Point at 'y' in "(+ x y)" which is column 5
        let diag = Diagnostic::error(
            "type mismatch",
            Span::new(3, 6, 3, 7),
        )
        .with_code("E0001")
        .with_help("expected i64, found bool");

        let source = "(define x true)\n(define y 42)\n(+ x y)\n";
        let out = format_diagnostic(&diag, source, "test.tl");

        assert!(out.contains("error[E0001]: type mismatch"));
        assert!(out.contains("--> test.tl:3:6"));
        assert!(out.contains(" 3 | (+ x y)"), "got:\n{}", out);
        assert!(out.contains("^"), "no caret found; got:\n{}", out);
        assert!(out.contains("= help: expected i64, found bool"));
    }
}
