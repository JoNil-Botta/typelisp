#![allow(dead_code)]

/// Source location span: start and end position in a file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start_line: usize,
    pub start_col: usize,
    pub end_line: usize,
    pub end_col: usize,
}

impl Span {
    pub fn new(start_line: usize, start_col: usize, end_line: usize, end_col: usize) -> Self {
        Span {
            start_line,
            start_col,
            end_line,
            end_col,
        }
    }

    pub fn point(line: usize, col: usize) -> Self {
        Span::new(line, col, line, col)
    }

    pub fn merge(&self, other: &Span) -> Span {
        Span::new(
            self.start_line,
            self.start_col,
            other.end_line,
            other.end_col,
        )
    }
}

impl Default for Span {
    fn default() -> Self {
        Span::point(0, 0)
    }
}
