use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};

pub const MANIFEST_FILE: &str = "typelisp.pkg";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dependency {
    pub alias: String,
    pub root: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackageManifest {
    pub name: String,
    pub version: String,
    pub entry: PathBuf,
    pub manifest_path: PathBuf,
    pub root: PathBuf,
    pub dependencies: Vec<Dependency>,
}

impl PackageManifest {
    pub fn entry_path(&self) -> PathBuf {
        self.root.join(&self.entry)
    }

    pub fn output_asm_path(&self) -> PathBuf {
        self.root
            .join("target")
            .join("typelisp")
            .join(&self.name)
            .join(format!("{}.s", self.name))
    }

    /// Root directory for a dependency alias, or `None` if the alias
    /// is not declared in this manifest.
    #[allow(dead_code)]
    pub fn dependency_root(&self, alias: &str) -> Option<&Path> {
        self.dependencies
            .iter()
            .find(|d| d.alias == alias)
            .map(|d| d.root.as_path())
    }
}

#[derive(Debug)]
pub enum PackageError {
    Io { path: PathBuf, source: io::Error },
    ManifestNotFound { start: PathBuf },
    Parse { path: PathBuf, message: String },
}

impl std::fmt::Display for PackageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PackageError::Io { path, source } => {
                write!(
                    f,
                    "cannot read package manifest '{}': {}",
                    path.display(),
                    source
                )
            }
            PackageError::ManifestNotFound { start } => write!(
                f,
                "could not find {} from '{}' or any parent directory",
                MANIFEST_FILE,
                start.display()
            ),
            PackageError::Parse { path, message } => {
                write!(
                    f,
                    "invalid package manifest '{}': {}",
                    path.display(),
                    message
                )
            }
        }
    }
}

pub fn discover_manifest(start: &Path) -> Result<PathBuf, PackageError> {
    let mut dir = if start.is_dir() {
        start.to_path_buf()
    } else {
        start
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."))
    };

    loop {
        let candidate = dir.join(MANIFEST_FILE);
        if candidate.is_file() {
            return Ok(candidate);
        }
        if !dir.pop() {
            return Err(PackageError::ManifestNotFound {
                start: start.to_path_buf(),
            });
        }
    }
}

pub fn load_manifest(path: &Path) -> Result<PackageManifest, PackageError> {
    let source = fs::read_to_string(path).map_err(|source| PackageError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    let parsed = parse_manifest(&source).map_err(|message| PackageError::Parse {
        path: path.to_path_buf(),
        message,
    })?;
    let manifest_path = fs::canonicalize(path).map_err(|source| PackageError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    let root = manifest_path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));

    Ok(PackageManifest {
        name: parsed.name,
        version: parsed.version,
        entry: parsed.entry,
        manifest_path,
        root: root.clone(),
        dependencies: parsed
            .dependencies
            .into_iter()
            .map(|(alias, path)| {
                let dep_root = if path.is_absolute() {
                    path
                } else {
                    root.join(&path)
                };
                let dep_root = dep_root.canonicalize().unwrap_or_else(|_| dep_root);
                Dependency {
                    alias,
                    root: dep_root,
                }
            })
            .collect(),
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ParsedManifest {
    name: String,
    version: String,
    entry: PathBuf,
    dependencies: Vec<(String, PathBuf)>,
}

fn parse_manifest(source: &str) -> Result<ParsedManifest, String> {
    let tokens = tokenize_manifest(source)?;
    let mut parser = SexpParser { tokens, pos: 0 };
    let sexp = parser.parse_one()?;
    if parser.pos != parser.tokens.len() {
        let tok = &parser.tokens[parser.pos];
        return Err(format!(
            "expected exactly one top-level package form, found extra input at {}:{}",
            tok.line, tok.column
        ));
    }
    parse_package_form(&sexp)
}

fn parse_package_form(sexp: &Sexp) -> Result<ParsedManifest, String> {
    let Sexp::List(items) = sexp else {
        return Err("manifest must be a `(package ...)` form".into());
    };
    let Some(Sexp::Symbol(head)) = items.first() else {
        return Err("manifest must start with `package`".into());
    };
    if head != "package" {
        return Err(format!("expected `package` form, got `{}`", head));
    }

    let mut name = None;
    let mut version = None;
    let mut entry = None;
    let mut dependencies: Vec<(String, PathBuf)> = Vec::new();

    for field in &items[1..] {
        let Sexp::List(parts) = field else {
            return Err("package fields must be lists like `(name \"...\")`".into());
        };
        let Some(Sexp::Symbol(field_name)) = parts.first() else {
            return Err("package fields must start with a field name".into());
        };

        match field_name.as_str() {
            "dependencies" => {
                if !dependencies.is_empty() {
                    return Err("duplicate manifest field `dependencies`".into());
                }
                for dep in &parts[1..] {
                    let Sexp::List(dep_parts) = dep else {
                        return Err(
                            "dependency entries must be lists like `(alias \"...\")`".into()
                        );
                    };
                    if dep_parts.len() != 2 {
                        return Err("dependency entries must have exactly one path value".into());
                    }
                    let Sexp::Symbol(alias) = &dep_parts[0] else {
                        return Err("dependency alias must be a symbol".into());
                    };
                    let Sexp::String(path_str) = &dep_parts[1] else {
                        return Err("dependency path must be a string".into());
                    };
                    validate_package_name(alias)?;
                    if dependencies.iter().any(|(a, _)| a == alias) {
                        return Err(format!("duplicate dependency alias `{}`", alias));
                    }
                    dependencies.push((alias.clone(), PathBuf::from(path_str.clone())));
                }
            }
            other => {
                if parts.len() != 2 {
                    return Err(format!(
                        "manifest field `{}` must have exactly one value",
                        field_name
                    ));
                }
                let Sexp::String(value) = &parts[1] else {
                    return Err(format!("manifest field `{}` must be a string", field_name));
                };

                match other {
                    "name" => assign_field(&mut name, field_name, value.clone())?,
                    "version" => assign_field(&mut version, field_name, value.clone())?,
                    "entry" => assign_field(&mut entry, field_name, value.clone())?,
                    _ => return Err(format!("unknown manifest field `{}`", other)),
                }
            }
        }
    }

    let name = name.ok_or_else(|| "manifest missing required field `name`".to_string())?;
    let version = version.ok_or_else(|| "manifest missing required field `version`".to_string())?;
    let entry = entry.ok_or_else(|| "manifest missing required field `entry`".to_string())?;

    validate_package_name(&name)?;
    if version.is_empty() {
        return Err("manifest field `version` must not be empty".into());
    }
    let entry = PathBuf::from(entry);
    if entry.as_os_str().is_empty() {
        return Err("manifest field `entry` must not be empty".into());
    }
    if !is_normal_relative_path(&entry) {
        return Err(
            "manifest field `entry` must be a normal relative path below the manifest directory"
                .into(),
        );
    }

    Ok(ParsedManifest {
        name,
        version,
        entry,
        dependencies,
    })
}

fn is_normal_relative_path(path: &Path) -> bool {
    !path.as_os_str().is_empty()
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
}

fn assign_field(slot: &mut Option<String>, field_name: &str, value: String) -> Result<(), String> {
    if slot.is_some() {
        return Err(format!("duplicate manifest field `{}`", field_name));
    }
    *slot = Some(value);
    Ok(())
}

fn validate_package_name(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("manifest field `name` must not be empty".into());
    }
    if !name
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
    {
        return Err(
            "manifest field `name` may only contain ASCII letters, digits, '-' and '_'".into(),
        );
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Sexp {
    List(Vec<Sexp>),
    Symbol(String),
    String(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Token {
    kind: TokenKind,
    line: usize,
    column: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum TokenKind {
    LParen,
    RParen,
    Symbol(String),
    String(String),
}

struct SexpParser {
    tokens: Vec<Token>,
    pos: usize,
}

impl SexpParser {
    fn parse_one(&mut self) -> Result<Sexp, String> {
        let Some(token) = self.tokens.get(self.pos).cloned() else {
            return Err("manifest is empty".into());
        };
        self.pos += 1;
        match token.kind {
            TokenKind::LParen => {
                let mut items = Vec::new();
                loop {
                    let Some(next) = self.tokens.get(self.pos) else {
                        return Err(format!(
                            "unclosed list starting before {}:{}",
                            token.line, token.column
                        ));
                    };
                    if matches!(next.kind, TokenKind::RParen) {
                        self.pos += 1;
                        return Ok(Sexp::List(items));
                    }
                    items.push(self.parse_one()?);
                }
            }
            TokenKind::RParen => Err(format!("unexpected `)` at {}:{}", token.line, token.column)),
            TokenKind::Symbol(symbol) => Ok(Sexp::Symbol(symbol)),
            TokenKind::String(value) => Ok(Sexp::String(value)),
        }
    }
}

fn tokenize_manifest(source: &str) -> Result<Vec<Token>, String> {
    let mut tokens = Vec::new();
    let mut chars = source.chars().peekable();
    let mut line = 1;
    let mut column = 1;

    while let Some(ch) = chars.next() {
        let token_line = line;
        let token_column = column;
        match ch {
            '(' => {
                tokens.push(Token {
                    kind: TokenKind::LParen,
                    line: token_line,
                    column: token_column,
                });
                column += 1;
            }
            ')' => {
                tokens.push(Token {
                    kind: TokenKind::RParen,
                    line: token_line,
                    column: token_column,
                });
                column += 1;
            }
            '"' => {
                column += 1;
                let value = read_manifest_string(&mut chars, &mut line, &mut column)
                    .map_err(|err| format!("{} at {}:{}", err, token_line, token_column))?;
                tokens.push(Token {
                    kind: TokenKind::String(value),
                    line: token_line,
                    column: token_column,
                });
            }
            ';' => {
                column += 1;
                for next in chars.by_ref() {
                    if next == '\n' {
                        line += 1;
                        column = 1;
                        break;
                    }
                    column += 1;
                }
            }
            '\n' => {
                line += 1;
                column = 1;
            }
            ch if ch.is_whitespace() => {
                column += 1;
            }
            _ => {
                let mut symbol = String::new();
                symbol.push(ch);
                column += 1;
                while let Some(&next) = chars.peek() {
                    if next.is_whitespace() || next == '(' || next == ')' || next == ';' {
                        break;
                    }
                    symbol.push(next);
                    chars.next();
                    column += 1;
                }
                tokens.push(Token {
                    kind: TokenKind::Symbol(symbol),
                    line: token_line,
                    column: token_column,
                });
            }
        }
    }

    Ok(tokens)
}

fn read_manifest_string<I>(
    chars: &mut std::iter::Peekable<I>,
    line: &mut usize,
    column: &mut usize,
) -> Result<String, &'static str>
where
    I: Iterator<Item = char>,
{
    let mut value = String::new();
    while let Some(ch) = chars.next() {
        match ch {
            '"' => {
                *column += 1;
                return Ok(value);
            }
            '\\' => {
                *column += 1;
                let Some(escaped) = chars.next() else {
                    return Err("unterminated string escape");
                };
                match escaped {
                    'n' => value.push('\n'),
                    'r' => value.push('\r'),
                    't' => value.push('\t'),
                    '"' => value.push('"'),
                    '\\' => value.push('\\'),
                    _ => return Err("unsupported string escape"),
                }
                *column += 1;
            }
            '\n' => {
                value.push('\n');
                *line += 1;
                *column = 1;
            }
            _ => {
                value.push(ch);
                *column += 1;
            }
        }
    }
    Err("unterminated string")
}

#[cfg(test)]
mod tests {
    use super::{PackageError, discover_manifest, load_manifest, parse_manifest};
    use std::fs;
    use std::path::Path;

    #[test]
    fn parse_manifest_accepts_required_fields() {
        let manifest = parse_manifest(
            r#"
; package comment
(package
  (name "demo-app")
  (version "0.1.0")
  (entry "src/main.tl"))
"#,
        )
        .expect("parse manifest");

        assert_eq!(manifest.name, "demo-app");
        assert_eq!(manifest.version, "0.1.0");
        assert_eq!(manifest.entry, Path::new("src/main.tl"));
    }

    #[test]
    fn parse_manifest_rejects_missing_field() {
        let err = parse_manifest(r#"(package (name "demo") (entry "src/main.tl"))"#)
            .expect_err("missing version should fail");
        assert!(err.contains("missing required field `version`"));
    }

    #[test]
    fn parse_manifest_rejects_duplicate_field() {
        let err = parse_manifest(
            r#"(package (name "demo") (name "again") (version "0.1.0") (entry "src/main.tl"))"#,
        )
        .expect_err("duplicate name should fail");
        assert!(err.contains("duplicate manifest field `name`"));
    }

    #[test]
    fn parse_manifest_rejects_unknown_field() {
        let err = parse_manifest(
            r#"(package (name "demo") (version "0.1.0") (entry "src/main.tl") (deps "nope"))"#,
        )
        .expect_err("unknown field should fail");
        assert!(err.contains("unknown manifest field `deps`"));
    }

    #[test]
    fn parse_manifest_rejects_mistyped_field() {
        let err =
            parse_manifest(r#"(package (name demo) (version "0.1.0") (entry "src/main.tl"))"#)
                .expect_err("symbol name should fail");
        assert!(err.contains("manifest field `name` must be a string"));
    }

    #[test]
    fn parse_manifest_rejects_absolute_entry() {
        let err =
            parse_manifest(r#"(package (name "demo") (version "0.1.0") (entry "/tmp/main.tl"))"#)
                .expect_err("absolute entry should fail");
        assert!(err.contains("normal relative path"));
    }

    #[test]
    fn discover_manifest_walks_upward() {
        let root =
            std::env::temp_dir().join(format!("typelisp-package-discover-{}", std::process::id()));
        let nested = root.join("a").join("b");
        fs::create_dir_all(&nested).expect("create nested test dir");
        fs::write(
            root.join("typelisp.pkg"),
            r#"(package (name "demo") (version "0.1.0") (entry "src/main.tl"))"#,
        )
        .expect("write manifest");

        let found = discover_manifest(&nested).expect("discover manifest");
        assert_eq!(found, root.join("typelisp.pkg"));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn load_manifest_records_root_and_paths() {
        let root =
            std::env::temp_dir().join(format!("typelisp-package-load-{}", std::process::id()));
        fs::create_dir_all(&root).expect("create package test dir");
        let manifest_path = root.join("typelisp.pkg");
        fs::write(
            &manifest_path,
            r#"(package (name "demo") (version "0.1.0") (entry "src/main.tl"))"#,
        )
        .expect("write manifest");

        let manifest = load_manifest(&manifest_path).expect("load manifest");
        assert_eq!(manifest.name, "demo");
        assert_eq!(manifest.entry_path(), manifest.root.join("src/main.tl"));
        assert_eq!(
            manifest.output_asm_path(),
            manifest.root.join("target/typelisp/demo/demo.s")
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn discover_manifest_reports_missing_manifest() {
        let root =
            std::env::temp_dir().join(format!("typelisp-package-missing-{}", std::process::id()));
        fs::create_dir_all(&root).expect("create package test dir");
        let err = discover_manifest(&root).expect_err("missing manifest should fail");
        assert!(matches!(err, PackageError::ManifestNotFound { .. }));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn parse_manifest_accepts_dependencies() {
        let manifest = parse_manifest(
            r#"
(package
  (name "app")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies
    (math "../math")
    (text "libs/text")))
"#,
        )
        .expect("parse manifest with dependencies");
        assert_eq!(manifest.dependencies.len(), 2);
        assert_eq!(manifest.dependencies[0].0, "math");
        assert_eq!(manifest.dependencies[0].1, Path::new("../math"));
        assert_eq!(manifest.dependencies[1].0, "text");
        assert_eq!(manifest.dependencies[1].1, Path::new("libs/text"));
    }

    #[test]
    fn parse_manifest_rejects_duplicate_dependency_alias() {
        let err = parse_manifest(
            r#"
(package
  (name "app")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies
    (math "../math")
    (math "../other")))
"#,
        )
        .expect_err("duplicate alias should fail");
        assert!(err.contains("duplicate dependency alias `math`"));
    }

    #[test]
    fn load_manifest_resolves_dependency_path() {
        let root = std::env::temp_dir().join(format!("typelisp-dep-load-{}", std::process::id()));
        let dep_dir = root.join("math-lib");
        fs::create_dir_all(&dep_dir).expect("create dep dir");
        let manifest_path = root.join("typelisp.pkg");
        fs::write(
            &manifest_path,
            r#"(package
  (name "app")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies (math "math-lib")))
"#,
        )
        .expect("write manifest");

        let manifest = load_manifest(&manifest_path).expect("load manifest");
        assert_eq!(manifest.dependencies.len(), 1);
        assert_eq!(manifest.dependencies[0].alias, "math");
        assert_eq!(
            manifest.dependencies[0].root,
            dep_dir.canonicalize().unwrap()
        );

        let _ = fs::remove_dir_all(&root);
    }
}
