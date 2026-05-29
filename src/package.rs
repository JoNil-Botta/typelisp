use crate::backend::{BackendOs, BackendTarget};
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};

pub const MANIFEST_FILE: &str = "typelisp.pkg";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PackageKind {
    Bin,
    Lib,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackageManifest {
    pub name: String,
    pub version: String,
    pub kind: PackageKind,
    pub entry: PathBuf,
    pub dependencies: BTreeMap<String, PathBuf>,
    pub link: BTreeMap<String, PackageLinkInputs>,
    pub manifest_path: PathBuf,
    pub root: PathBuf,
}

impl PackageManifest {
    pub fn entry_path(&self) -> PathBuf {
        self.root.join(&self.entry)
    }

    pub fn output_dir(&self) -> PathBuf {
        self.root.join("target").join("typelisp").join(&self.name)
    }

    pub fn output_asm_path(&self) -> PathBuf {
        self.output_dir().join(format!("{}.s", self.name))
    }

    pub fn output_obj_path(&self, target: BackendTarget) -> PathBuf {
        self.output_dir()
            .join(format!("{}.{}", self.name, target.object_extension()))
    }

    pub fn output_bin_path(&self, target: BackendTarget) -> PathBuf {
        match target.executable_extension() {
            Some(extension) => self
                .output_dir()
                .join(format!("{}.{}", self.name, extension)),
            None => self.output_dir().join(&self.name),
        }
    }

    pub fn output_lib_path(&self, target: BackendTarget) -> PathBuf {
        match target.os {
            BackendOs::Linux => self.output_dir().join(format!("lib{}.a", self.name)),
            BackendOs::Windows => self.output_dir().join(format!("{}.lib", self.name)),
        }
    }

    pub fn output_artifact_path(&self, target: BackendTarget) -> PathBuf {
        match self.kind {
            PackageKind::Bin => self.output_bin_path(target),
            PackageKind::Lib => self.output_lib_path(target),
        }
    }

    pub fn link_inputs_for_target(&self, target: BackendTarget) -> PackageLinkInputs {
        self.link.get(target.as_str()).cloned().unwrap_or_default()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PackageLinkInputs {
    pub libs: Vec<String>,
    pub search_paths: Vec<PathBuf>,
    pub args: Vec<String>,
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

    let dependencies = parsed
        .dependencies
        .into_iter()
        .map(|(alias, path)| {
            let root_path = if path.is_absolute() {
                path
            } else {
                root.join(path)
            };
            (alias, root_path)
        })
        .collect();
    let link = parsed
        .link
        .into_iter()
        .map(|(target, inputs)| (target, inputs.resolve_paths(&root)))
        .collect();

    Ok(PackageManifest {
        name: parsed.name,
        version: parsed.version,
        kind: parsed.kind,
        entry: parsed.entry,
        dependencies,
        link,
        manifest_path,
        root,
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ParsedManifest {
    name: String,
    version: String,
    kind: PackageKind,
    entry: PathBuf,
    dependencies: BTreeMap<String, PathBuf>,
    link: BTreeMap<String, PackageLinkInputs>,
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
    let mut kind = None;
    let mut entry = None;
    let mut dependencies = None;
    let mut link = None;

    for field in &items[1..] {
        let Sexp::List(parts) = field else {
            return Err("package fields must be lists like `(name \"...\")`".into());
        };
        let Some(Sexp::Symbol(field_name)) = parts.first() else {
            return Err("package fields must start with a field name".into());
        };

        match field_name.as_str() {
            "name" => {
                let value = parse_string_field(parts, field_name)?;
                assign_field(&mut name, field_name, value)?;
            }
            "version" => {
                let value = parse_string_field(parts, field_name)?;
                assign_field(&mut version, field_name, value)?;
            }
            "kind" => {
                let value = parse_package_kind(&parse_string_field(parts, field_name)?)?;
                assign_field(&mut kind, field_name, value)?;
            }
            "entry" => {
                let value = parse_string_field(parts, field_name)?;
                assign_field(&mut entry, field_name, value)?;
            }
            "dependencies" => assign_dependencies_field(
                &mut dependencies,
                field_name,
                parse_dependencies_field(parts)?,
            )?,
            "link" => assign_link_field(&mut link, field_name, parse_link_field(parts)?)?,
            other => return Err(format!("unknown manifest field `{}`", other)),
        }
    }

    let name = name.ok_or_else(|| "manifest missing required field `name`".to_string())?;
    let version = version.ok_or_else(|| "manifest missing required field `version`".to_string())?;
    let kind = kind.ok_or_else(|| "manifest missing required field `kind`".to_string())?;
    let entry = entry.ok_or_else(|| "manifest missing required field `entry`".to_string())?;
    let dependencies = dependencies.unwrap_or_default();
    let link = link.unwrap_or_default();

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
        kind,
        entry,
        dependencies,
        link,
    })
}

fn parse_package_kind(value: &str) -> Result<PackageKind, String> {
    match value {
        "bin" => Ok(PackageKind::Bin),
        "lib" => Ok(PackageKind::Lib),
        _ => Err("manifest field `kind` must be `bin` or `lib`".into()),
    }
}

fn parse_string_field(parts: &[Sexp], field_name: &str) -> Result<String, String> {
    if parts.len() != 2 {
        return Err(format!(
            "manifest field `{}` must have exactly one value",
            field_name
        ));
    }
    let Sexp::String(value) = &parts[1] else {
        return Err(format!("manifest field `{}` must be a string", field_name));
    };
    Ok(value.clone())
}

fn parse_dependencies_field(parts: &[Sexp]) -> Result<BTreeMap<String, PathBuf>, String> {
    let mut dependencies = BTreeMap::new();
    for dep in &parts[1..] {
        let Sexp::List(dep_parts) = dep else {
            return Err("manifest dependency entries must be lists like `(alias \"path\")`".into());
        };
        if dep_parts.len() != 2 {
            return Err("manifest dependency entries must have exactly an alias and a path".into());
        }
        let Some(Sexp::Symbol(alias)) = dep_parts.first() else {
            return Err("manifest dependency entries must start with an alias".into());
        };
        let Sexp::String(path) = &dep_parts[1] else {
            return Err(format!(
                "manifest dependency `{}` path must be a string",
                alias
            ));
        };
        validate_dependency_alias(alias)?;
        if path.is_empty() {
            return Err(format!(
                "manifest dependency `{}` path must not be empty",
                alias
            ));
        }
        if dependencies
            .insert(alias.clone(), PathBuf::from(path))
            .is_some()
        {
            return Err(format!("duplicate dependency alias `{}`", alias));
        }
    }
    Ok(dependencies)
}

fn parse_link_field(parts: &[Sexp]) -> Result<BTreeMap<String, PackageLinkInputs>, String> {
    let mut targets = BTreeMap::new();
    for target in &parts[1..] {
        let Sexp::List(target_parts) = target else {
            return Err(
                "manifest link entries must be target lists like `(linux-x86_64 ...)`".into(),
            );
        };
        let Some(Sexp::Symbol(target_name)) = target_parts.first() else {
            return Err("manifest link entries must start with a target name".into());
        };
        let target_key = parse_link_target_name(target_name)?;
        if targets
            .insert(target_key.clone(), parse_link_target_field(target_parts)?)
            .is_some()
        {
            return Err(format!("duplicate link target `{}`", target_name));
        }
    }
    Ok(targets)
}

fn parse_link_target_name(value: &str) -> Result<String, String> {
    match value {
        "linux-x86_64" | "linux_x86_64" => Ok("linux-x86_64".into()),
        "windows-x86_64" | "windows_x86_64" => Ok("windows-x86_64".into()),
        _ => Err(format!("unknown link target `{}`", value)),
    }
}

fn parse_link_target_field(parts: &[Sexp]) -> Result<PackageLinkInputs, String> {
    let mut libs = None;
    let mut search_paths = None;
    let mut args = None;
    for field in &parts[1..] {
        let Sexp::List(field_parts) = field else {
            return Err("manifest link target fields must be lists".into());
        };
        let Some(Sexp::Symbol(field_name)) = field_parts.first() else {
            return Err("manifest link target fields must start with a field name".into());
        };
        match field_name.as_str() {
            "libs" => assign_field(
                &mut libs,
                field_name,
                parse_string_list_field(field_parts, field_name)?,
            )?,
            "search" => assign_field(
                &mut search_paths,
                field_name,
                parse_path_list_field(field_parts, field_name)?,
            )?,
            "args" => assign_field(
                &mut args,
                field_name,
                parse_string_list_field(field_parts, field_name)?,
            )?,
            other => return Err(format!("unknown manifest link field `{}`", other)),
        }
    }
    Ok(PackageLinkInputs {
        libs: libs.unwrap_or_default(),
        search_paths: search_paths.unwrap_or_default(),
        args: args.unwrap_or_default(),
    })
}

fn parse_string_list_field(parts: &[Sexp], field_name: &str) -> Result<Vec<String>, String> {
    let mut values = Vec::new();
    for value in &parts[1..] {
        let Sexp::String(text) = value else {
            return Err(format!(
                "manifest link field `{}` values must be strings",
                field_name
            ));
        };
        if text.is_empty() {
            return Err(format!(
                "manifest link field `{}` values must not be empty",
                field_name
            ));
        }
        values.push(text.clone());
    }
    Ok(values)
}

fn parse_path_list_field(parts: &[Sexp], field_name: &str) -> Result<Vec<PathBuf>, String> {
    parse_string_list_field(parts, field_name)
        .map(|paths| paths.into_iter().map(PathBuf::from).collect())
}

impl PackageLinkInputs {
    fn resolve_paths(self, root: &Path) -> Self {
        Self {
            libs: self.libs,
            search_paths: self
                .search_paths
                .into_iter()
                .map(|path| {
                    if path.is_absolute() {
                        path
                    } else {
                        root.join(path)
                    }
                })
                .collect(),
            args: self.args,
        }
    }
}

fn is_normal_relative_path(path: &Path) -> bool {
    !path.as_os_str().is_empty()
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
}

fn assign_field<T>(slot: &mut Option<T>, field_name: &str, value: T) -> Result<(), String> {
    if slot.is_some() {
        return Err(format!("duplicate manifest field `{}`", field_name));
    }
    *slot = Some(value);
    Ok(())
}

fn assign_dependencies_field(
    slot: &mut Option<BTreeMap<String, PathBuf>>,
    field_name: &str,
    value: BTreeMap<String, PathBuf>,
) -> Result<(), String> {
    if slot.is_some() {
        return Err(format!("duplicate manifest field `{}`", field_name));
    }
    *slot = Some(value);
    Ok(())
}

fn assign_link_field(
    slot: &mut Option<BTreeMap<String, PackageLinkInputs>>,
    field_name: &str,
    value: BTreeMap<String, PackageLinkInputs>,
) -> Result<(), String> {
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

fn validate_dependency_alias(alias: &str) -> Result<(), String> {
    if alias.is_empty() {
        return Err("dependency alias must not be empty".into());
    }
    if !alias
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
    {
        return Err("dependency alias may only contain ASCII letters, digits, '-' and '_'".into());
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
    use crate::backend::BackendTarget;

    use super::{PackageError, PackageKind, discover_manifest, load_manifest, parse_manifest};
    use std::fs;
    use std::path::{Path, PathBuf};

    #[test]
    fn parse_manifest_accepts_required_fields() {
        let manifest = parse_manifest(
            r#"
; package comment
(package
  (name "demo-app")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
"#,
        )
        .expect("parse manifest");

        assert_eq!(manifest.name, "demo-app");
        assert_eq!(manifest.version, "0.1.0");
        assert_eq!(manifest.kind, PackageKind::Bin);
        assert_eq!(manifest.entry, Path::new("src/main.tl"));
    }

    #[test]
    fn parse_manifest_accepts_dependencies() {
        let manifest = parse_manifest(
            r#"
(package
  (name "demo-app")
  (version "0.1.0")
  (kind "lib")
  (entry "src/main.tl")
  (dependencies
    (math "../math")
    (util "/opt/type-lisp/util")))
"#,
        )
        .expect("parse manifest");

        assert_eq!(manifest.dependencies.len(), 2);
        assert_eq!(manifest.kind, PackageKind::Lib);
        assert_eq!(
            manifest.dependencies.get("math"),
            Some(&PathBuf::from("../math"))
        );
        assert_eq!(
            manifest.dependencies.get("util"),
            Some(&PathBuf::from("/opt/type-lisp/util"))
        );
    }

    #[test]
    fn parse_manifest_accepts_per_target_link_inputs() {
        let manifest = parse_manifest(
            r#"
(package
  (name "demo-app")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (link
    (linux-x86_64
      (libs "m" "raylib")
      (search "native/linux")
      (args "--as-needed"))
    (windows-x86_64
      (libs "raylib")
      (search "native/windows")
      (args "/DEBUG"))))
"#,
        )
        .expect("parse manifest");

        let linux = manifest.link.get("linux-x86_64").expect("linux link");
        assert_eq!(linux.libs, vec!["m", "raylib"]);
        assert_eq!(linux.search_paths, vec![PathBuf::from("native/linux")]);
        assert_eq!(linux.args, vec!["--as-needed"]);
        let windows = manifest.link.get("windows-x86_64").expect("windows link");
        assert_eq!(windows.libs, vec!["raylib"]);
        assert_eq!(windows.search_paths, vec![PathBuf::from("native/windows")]);
        assert_eq!(windows.args, vec!["/DEBUG"]);
    }

    #[test]
    fn parse_manifest_rejects_bad_link_section() {
        let err = parse_manifest(
            r#"
(package
  (name "demo")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (link (macos-x86_64 (libs "m"))))
"#,
        )
        .expect_err("unknown link target should fail");
        assert!(err.contains("unknown link target `macos-x86_64`"));

        let err = parse_manifest(
            r#"
(package
  (name "demo")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (link (linux-x86_64 (libs m))))
"#,
        )
        .expect_err("non-string link lib should fail");
        assert!(err.contains("manifest link field `libs` values must be strings"));
    }

    #[test]
    fn parse_manifest_rejects_missing_field() {
        let err = parse_manifest(r#"(package (name "demo") (kind "bin") (entry "src/main.tl"))"#)
            .expect_err("missing version should fail");
        assert!(err.contains("missing required field `version`"));

        let err =
            parse_manifest(r#"(package (name "demo") (version "0.1.0") (entry "src/main.tl"))"#)
                .expect_err("missing kind should fail");
        assert!(err.contains("missing required field `kind`"));
    }

    #[test]
    fn parse_manifest_rejects_duplicate_field() {
        let err = parse_manifest(
            r#"(package (name "demo") (name "again") (version "0.1.0") (kind "bin") (entry "src/main.tl"))"#,
        )
        .expect_err("duplicate name should fail");
        assert!(err.contains("duplicate manifest field `name`"));
    }

    #[test]
    fn parse_manifest_rejects_duplicate_dependencies_field() {
        let err = parse_manifest(
            r#"(package
  (name "demo")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (dependencies (math "../math"))
  (dependencies (util "../util")))"#,
        )
        .expect_err("duplicate dependencies should fail");
        assert!(err.contains("duplicate manifest field `dependencies`"));
    }

    #[test]
    fn parse_manifest_rejects_duplicate_dependency_alias() {
        let err = parse_manifest(
            r#"(package
  (name "demo")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (dependencies
    (math "../math-a")
    (math "../math-b")))"#,
        )
        .expect_err("duplicate dependency alias should fail");
        assert!(err.contains("duplicate dependency alias `math`"));
    }

    #[test]
    fn parse_manifest_rejects_invalid_dependency_alias() {
        let err = parse_manifest(
            r#"(package
  (name "demo")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (dependencies
    (bad.alias "../bad")))"#,
        )
        .expect_err("invalid dependency alias should fail");
        assert!(err.contains("dependency alias may only contain ASCII letters"));
    }

    #[test]
    fn parse_manifest_rejects_invalid_kind() {
        let err = parse_manifest(
            r#"(package (name "demo") (version "0.1.0") (kind "cdylib") (entry "src/main.tl"))"#,
        )
        .expect_err("invalid kind should fail");
        assert!(err.contains("manifest field `kind` must be `bin` or `lib`"));
    }

    #[test]
    fn parse_manifest_rejects_unknown_field() {
        let err = parse_manifest(
            r#"(package (name "demo") (version "0.1.0") (kind "bin") (entry "src/main.tl") (deps "nope"))"#,
        )
        .expect_err("unknown field should fail");
        assert!(err.contains("unknown manifest field `deps`"));
    }

    #[test]
    fn parse_manifest_rejects_mistyped_field() {
        let err = parse_manifest(
            r#"(package (name demo) (version "0.1.0") (kind "bin") (entry "src/main.tl"))"#,
        )
        .expect_err("symbol name should fail");
        assert!(err.contains("manifest field `name` must be a string"));
    }

    #[test]
    fn parse_manifest_rejects_absolute_entry() {
        let err = parse_manifest(
            r#"(package (name "demo") (version "0.1.0") (kind "bin") (entry "/tmp/main.tl"))"#,
        )
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
            r#"(package (name "demo") (version "0.1.0") (kind "bin") (entry "src/main.tl"))"#,
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
            r#"(package (name "demo") (version "0.1.0") (kind "bin") (entry "src/main.tl"))"#,
        )
        .expect("write manifest");

        let manifest = load_manifest(&manifest_path).expect("load manifest");
        assert_eq!(manifest.name, "demo");
        assert_eq!(manifest.kind, PackageKind::Bin);
        assert_eq!(manifest.entry_path(), manifest.root.join("src/main.tl"));
        assert!(manifest.dependencies.is_empty());
        assert_eq!(
            manifest.output_asm_path(),
            manifest.root.join("target/typelisp/demo/demo.s")
        );
        assert_eq!(
            manifest.output_obj_path(BackendTarget::linux_x86_64_system_v()),
            manifest.root.join("target/typelisp/demo/demo.o")
        );
        assert_eq!(
            manifest.output_artifact_path(BackendTarget::linux_x86_64_system_v()),
            manifest.root.join("target/typelisp/demo/demo")
        );
        assert_eq!(
            manifest.output_artifact_path(BackendTarget::windows_x86_64()),
            manifest.root.join("target/typelisp/demo/demo.exe")
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn load_manifest_resolves_dependency_paths_from_root() {
        let root =
            std::env::temp_dir().join(format!("typelisp-package-load-deps-{}", std::process::id()));
        fs::create_dir_all(&root).expect("create package test dir");
        let manifest_path = root.join("typelisp.pkg");
        fs::write(
            &manifest_path,
            r#"(package
  (name "demo")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (dependencies
    (math "../math")
    (util "vendor/util")))"#,
        )
        .expect("write manifest");

        let manifest = load_manifest(&manifest_path).expect("load manifest");
        assert_eq!(
            manifest.dependencies.get("math"),
            Some(&manifest.root.join("../math"))
        );
        assert_eq!(
            manifest.dependencies.get("util"),
            Some(&manifest.root.join("vendor/util"))
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn load_manifest_resolves_link_search_paths_from_root() {
        let root =
            std::env::temp_dir().join(format!("typelisp-package-load-link-{}", std::process::id()));
        fs::create_dir_all(&root).expect("create package test dir");
        let manifest_path = root.join("typelisp.pkg");
        let absolute_search = if cfg!(windows) {
            "C:/type-lisp/lib"
        } else {
            "/opt/type-lisp/lib"
        };
        fs::write(
            &manifest_path,
            format!(
                r#"(package
  (name "demo")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl")
  (link
    (linux-x86_64
      (libs "m")
      (search "native/lib" "{}")
      (args "--as-needed"))))"#,
                absolute_search
            ),
        )
        .expect("write manifest");

        let manifest = load_manifest(&manifest_path).expect("load manifest");
        let link = manifest.link_inputs_for_target(BackendTarget::linux_x86_64_system_v());
        assert_eq!(link.libs, vec!["m"]);
        assert_eq!(
            link.search_paths,
            vec![
                manifest.root.join("native/lib"),
                PathBuf::from(absolute_search)
            ]
        );
        assert_eq!(link.args, vec!["--as-needed"]);

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
}
