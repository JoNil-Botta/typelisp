use crate::diagnostic::{Diagnostic, Level};
use crate::module::{LoadError, LoadOptions, ModuleSource, SourceFile, load_program_with_options};
use crate::span::Span;
use crate::typechecker::TypeChecker;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

const JSONRPC_VERSION: &str = "2.0";
const METHOD_NOT_FOUND: i64 = -32601;
const PARSE_ERROR: i64 = -32700;

#[derive(Debug, Clone, PartialEq)]
enum Json {
    Null,
    Bool(bool),
    Number(String),
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

impl Json {
    fn number(n: i64) -> Self {
        Json::Number(n.to_string())
    }

    fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(fields) => fields
                .iter()
                .find_map(|(field, value)| (field == key).then_some(value)),
            _ => None,
        }
    }

    fn as_str(&self) -> Option<&str> {
        match self {
            Json::String(value) => Some(value),
            _ => None,
        }
    }

    fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(values) => Some(values),
            _ => None,
        }
    }

    fn stringify(&self) -> String {
        match self {
            Json::Null => "null".to_string(),
            Json::Bool(value) => value.to_string(),
            Json::Number(value) => value.clone(),
            Json::String(value) => format!("\"{}\"", escape_json_string(value)),
            Json::Array(values) => {
                let items = values
                    .iter()
                    .map(Json::stringify)
                    .collect::<Vec<_>>()
                    .join(",");
                format!("[{}]", items)
            }
            Json::Object(fields) => {
                let items = fields
                    .iter()
                    .map(|(key, value)| {
                        format!("\"{}\":{}", escape_json_string(key), value.stringify())
                    })
                    .collect::<Vec<_>>()
                    .join(",");
                format!("{{{}}}", items)
            }
        }
    }
}

fn json_object(fields: Vec<(&str, Json)>) -> Json {
    Json::Object(
        fields
            .into_iter()
            .map(|(key, value)| (key.to_string(), value))
            .collect(),
    )
}

fn json_object_owned(fields: Vec<(String, Json)>) -> Json {
    Json::Object(fields)
}

fn escape_json_string(value: &str) -> String {
    let mut out = String::new();
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            ch if ch.is_control() => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out
}

struct JsonParser {
    chars: Vec<char>,
    pos: usize,
}

impl JsonParser {
    fn new(text: &str) -> Self {
        JsonParser {
            chars: text.chars().collect(),
            pos: 0,
        }
    }

    fn parse(mut self) -> Result<Json, String> {
        let value = self.parse_value()?;
        self.skip_ws();
        if self.pos == self.chars.len() {
            Ok(value)
        } else {
            Err("trailing characters after JSON value".to_string())
        }
    }

    fn parse_value(&mut self) -> Result<Json, String> {
        self.skip_ws();
        let Some(ch) = self.peek() else {
            return Err("expected JSON value".to_string());
        };
        match ch {
            'n' => self.parse_keyword("null", Json::Null),
            't' => self.parse_keyword("true", Json::Bool(true)),
            'f' => self.parse_keyword("false", Json::Bool(false)),
            '"' => self.parse_string().map(Json::String),
            '[' => self.parse_array(),
            '{' => self.parse_object(),
            '-' | '0'..='9' => self.parse_number(),
            _ => Err(format!("unexpected JSON character '{}'", ch)),
        }
    }

    fn parse_keyword(&mut self, keyword: &str, value: Json) -> Result<Json, String> {
        for expected in keyword.chars() {
            if self.next() != Some(expected) {
                return Err(format!("expected JSON keyword '{}'", keyword));
            }
        }
        Ok(value)
    }

    fn parse_string(&mut self) -> Result<String, String> {
        self.expect('"')?;
        let mut out = String::new();
        while let Some(ch) = self.next() {
            match ch {
                '"' => return Ok(out),
                '\\' => {
                    let escaped = self
                        .next()
                        .ok_or_else(|| "unterminated JSON escape".to_string())?;
                    match escaped {
                        '"' => out.push('"'),
                        '\\' => out.push('\\'),
                        '/' => out.push('/'),
                        'b' => out.push('\u{08}'),
                        'f' => out.push('\u{0c}'),
                        'n' => out.push('\n'),
                        'r' => out.push('\r'),
                        't' => out.push('\t'),
                        'u' => out.push(self.parse_unicode_escape()?),
                        _ => return Err(format!("unsupported JSON escape '\\{}'", escaped)),
                    }
                }
                ch if ch.is_control() => {
                    return Err("control character in JSON string".to_string());
                }
                ch => out.push(ch),
            }
        }
        Err("unterminated JSON string".to_string())
    }

    fn parse_unicode_escape(&mut self) -> Result<char, String> {
        let mut value = 0u32;
        for _ in 0..4 {
            let ch = self
                .next()
                .ok_or_else(|| "unterminated unicode escape".to_string())?;
            let digit = ch
                .to_digit(16)
                .ok_or_else(|| format!("invalid unicode escape digit '{}'", ch))?;
            value = value * 16 + digit;
        }
        Ok(std::char::from_u32(value).unwrap_or('\u{fffd}'))
    }

    fn parse_array(&mut self) -> Result<Json, String> {
        self.expect('[')?;
        let mut values = Vec::new();
        loop {
            self.skip_ws();
            if self.consume(']') {
                break;
            }
            values.push(self.parse_value()?);
            self.skip_ws();
            if self.consume(']') {
                break;
            }
            self.expect(',')?;
        }
        Ok(Json::Array(values))
    }

    fn parse_object(&mut self) -> Result<Json, String> {
        self.expect('{')?;
        let mut fields = Vec::new();
        loop {
            self.skip_ws();
            if self.consume('}') {
                break;
            }
            let key = self.parse_string()?;
            self.skip_ws();
            self.expect(':')?;
            let value = self.parse_value()?;
            fields.push((key, value));
            self.skip_ws();
            if self.consume('}') {
                break;
            }
            self.expect(',')?;
        }
        Ok(Json::Object(fields))
    }

    fn parse_number(&mut self) -> Result<Json, String> {
        let start = self.pos;
        self.consume('-');
        self.consume_digits();
        if self.consume('.') {
            self.consume_digits();
        }
        if self.consume('e') || self.consume('E') {
            if matches!(self.peek(), Some('+' | '-')) {
                self.pos += 1;
            }
            self.consume_digits();
        }
        if start == self.pos {
            return Err("expected JSON number".to_string());
        }
        Ok(Json::Number(self.chars[start..self.pos].iter().collect()))
    }

    fn consume_digits(&mut self) {
        while matches!(self.peek(), Some('0'..='9')) {
            self.pos += 1;
        }
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(' ' | '\n' | '\r' | '\t')) {
            self.pos += 1;
        }
    }

    fn expect(&mut self, expected: char) -> Result<(), String> {
        if self.next() == Some(expected) {
            Ok(())
        } else {
            Err(format!("expected JSON character '{}'", expected))
        }
    }

    fn consume(&mut self, expected: char) -> bool {
        if self.peek() == Some(expected) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn next(&mut self) -> Option<char> {
        let ch = self.peek()?;
        self.pos += 1;
        Some(ch)
    }
}

fn parse_json(text: &str) -> Result<Json, String> {
    JsonParser::new(text).parse()
}

#[derive(Debug, Clone)]
struct OpenDocument {
    path: PathBuf,
    text: String,
}

struct LspServer {
    documents: HashMap<String, OpenDocument>,
    published_diagnostics: HashMap<String, BTreeSet<String>>,
    options: LoadOptions,
    shutdown_requested: bool,
}

impl LspServer {
    fn new(options: LoadOptions) -> Self {
        LspServer {
            documents: HashMap::new(),
            published_diagnostics: HashMap::new(),
            options,
            shutdown_requested: false,
        }
    }

    fn handle_message(&mut self, message: Json, writer: &mut impl Write) -> io::Result<bool> {
        let Some(method) = message.get("method").and_then(Json::as_str) else {
            return Ok(false);
        };
        let id = message.get("id").cloned();
        match method {
            "initialize" => {
                if let Some(id) = id {
                    write_response(writer, id, initialize_result())?;
                }
            }
            "initialized" => {}
            "shutdown" => {
                self.shutdown_requested = true;
                if let Some(id) = id {
                    write_response(writer, id, Json::Null)?;
                }
            }
            "exit" => return Ok(true),
            "textDocument/didOpen" => {
                if let Some(params) = message.get("params") {
                    self.did_open(params, writer)?;
                }
            }
            "textDocument/didChange" => {
                if let Some(params) = message.get("params") {
                    self.did_change(params, writer)?;
                }
            }
            "textDocument/didClose" => {
                if let Some(params) = message.get("params") {
                    self.did_close(params, writer)?;
                }
            }
            _ => {
                if let Some(id) = id {
                    write_error(writer, id, METHOD_NOT_FOUND, "Method not found")?;
                }
            }
        }
        Ok(false)
    }

    fn did_open(&mut self, params: &Json, writer: &mut impl Write) -> io::Result<()> {
        let Some(document) = params.get("textDocument") else {
            return Ok(());
        };
        let Some(uri) = document.get("uri").and_then(Json::as_str) else {
            return Ok(());
        };
        let text = document
            .get("text")
            .and_then(Json::as_str)
            .unwrap_or("")
            .to_string();
        let Some(path) = file_uri_to_path(uri) else {
            publish_diagnostics(
                writer,
                uri,
                vec![lsp_diagnostic(&Diagnostic::error(
                    "unsupported TypeLisp LSP URI: expected file:// URI",
                    Span::new(1, 1, 1, 1),
                ))],
            )?;
            return Ok(());
        };
        self.documents
            .insert(uri.to_string(), OpenDocument { path, text });
        self.publish_analysis(uri, writer)
    }

    fn did_change(&mut self, params: &Json, writer: &mut impl Write) -> io::Result<()> {
        let Some(document) = params.get("textDocument") else {
            return Ok(());
        };
        let Some(uri) = document.get("uri").and_then(Json::as_str) else {
            return Ok(());
        };
        let text = params
            .get("contentChanges")
            .and_then(Json::as_array)
            .and_then(|changes| changes.first())
            .and_then(|change| change.get("text"))
            .and_then(Json::as_str)
            .map(str::to_string);
        let Some(text) = text else {
            return self.publish_analysis(uri, writer);
        };
        if let Some(open) = self.documents.get_mut(uri) {
            open.text = text;
        } else if let Some(path) = file_uri_to_path(uri) {
            self.documents
                .insert(uri.to_string(), OpenDocument { path, text });
        } else {
            publish_diagnostics(
                writer,
                uri,
                vec![lsp_diagnostic(&Diagnostic::error(
                    "unsupported TypeLisp LSP URI: expected file:// URI",
                    Span::new(1, 1, 1, 1),
                ))],
            )?;
            return Ok(());
        }
        self.publish_analysis(uri, writer)
    }

    fn did_close(&mut self, params: &Json, writer: &mut impl Write) -> io::Result<()> {
        let Some(document) = params.get("textDocument") else {
            return Ok(());
        };
        let Some(uri) = document.get("uri").and_then(Json::as_str) else {
            return Ok(());
        };
        self.documents.remove(uri);
        let mut stale_uris = self.published_diagnostics.remove(uri).unwrap_or_default();
        stale_uris.insert(uri.to_string());
        for stale_uri in stale_uris {
            publish_diagnostics(writer, &stale_uri, Vec::new())?;
        }
        Ok(())
    }

    fn publish_analysis(&mut self, uri: &str, writer: &mut impl Write) -> io::Result<()> {
        let Some(open) = self.documents.get(uri) else {
            return Ok(());
        };
        let mut diagnostics = self.analyze_document(uri, open);
        diagnostics.entry(uri.to_string()).or_default();
        let current_uris = diagnostics.keys().cloned().collect::<BTreeSet<_>>();
        if let Some(previous_uris) = self.published_diagnostics.get(uri) {
            for stale_uri in previous_uris.difference(&current_uris) {
                publish_diagnostics(writer, stale_uri, Vec::new())?;
            }
        }
        for (diag_uri, items) in diagnostics {
            publish_diagnostics(writer, &diag_uri, items)?;
        }
        self.published_diagnostics
            .insert(uri.to_string(), current_uris);
        Ok(())
    }

    fn analyze_document(&self, root_uri: &str, open: &OpenDocument) -> BTreeMap<String, Vec<Json>> {
        let source = OverlaySource::new(&open.path, &open.text);
        let mut diagnostics: BTreeMap<String, Vec<Json>> = BTreeMap::new();
        match load_program_with_options(&open.path, &source, &self.options) {
            Ok(loaded) => {
                let mut checker = TypeChecker::new();
                if let Err(err) = checker.check_program(&loaded.program) {
                    let diag = err.to_diagnostic();
                    let uri = diagnostic_uri(&diag, &loaded.sources)
                        .unwrap_or_else(|| root_uri.to_string());
                    diagnostics
                        .entry(uri)
                        .or_default()
                        .push(lsp_diagnostic(&diag));
                }
            }
            Err(err) => {
                let (uri, diag) = load_error_diagnostic(root_uri, err);
                diagnostics.entry(uri).or_default().push(diag);
            }
        }
        diagnostics
    }
}

fn initialize_result() -> Json {
    json_object(vec![
        (
            "capabilities",
            json_object(vec![(
                "textDocumentSync",
                json_object(vec![
                    ("openClose", Json::Bool(true)),
                    ("change", Json::number(1)),
                ]),
            )]),
        ),
        (
            "serverInfo",
            json_object(vec![
                ("name", Json::String("typelisp".to_string())),
                (
                    "version",
                    Json::String(env!("CARGO_PKG_VERSION").to_string()),
                ),
            ]),
        ),
    ])
}

fn diagnostic_uri(diag: &Diagnostic, sources: &[SourceFile]) -> Option<String> {
    sources
        .iter()
        .find(|source| source.id == diag.span.file_id)
        .map(|source| path_to_file_uri(&source.path))
}

fn load_error_diagnostic(root_uri: &str, err: LoadError) -> (String, Json) {
    match err {
        LoadError::Parse {
            path,
            source_text: _,
            error,
        } => {
            let diag = error.to_diagnostic();
            (path_to_file_uri(&path), lsp_diagnostic(&diag))
        }
        err => {
            let diag = Diagnostic::error(err.to_string(), Span::new(1, 1, 1, 1));
            (root_uri.to_string(), lsp_diagnostic(&diag))
        }
    }
}

fn lsp_diagnostic(diag: &Diagnostic) -> Json {
    let mut fields = vec![
        ("range".to_string(), lsp_range(diag.span)),
        (
            "severity".to_string(),
            Json::number(match diag.level {
                Level::Error => 1,
                Level::Warning => 2,
                Level::Note => 3,
            }),
        ),
        ("source".to_string(), Json::String("typelisp".to_string())),
    ];
    if let Some(code) = &diag.code {
        fields.push(("code".to_string(), Json::String(code.clone())));
    }
    fields.push(("message".to_string(), Json::String(diag.message.clone())));
    Json::Object(fields)
}

fn lsp_range(span: Span) -> Json {
    json_object(vec![
        (
            "start",
            json_object(vec![
                ("line", Json::number(zero_based(span.start_line))),
                ("character", Json::number(zero_based(span.start_col))),
            ]),
        ),
        (
            "end",
            json_object(vec![
                ("line", Json::number(zero_based(span.end_line))),
                ("character", Json::number(zero_based(span.end_col))),
            ]),
        ),
    ])
}

fn zero_based(value: usize) -> i64 {
    value.saturating_sub(1) as i64
}

fn publish_diagnostics(
    writer: &mut impl Write,
    uri: &str,
    diagnostics: Vec<Json>,
) -> io::Result<()> {
    write_notification(
        writer,
        "textDocument/publishDiagnostics",
        json_object(vec![
            ("uri", Json::String(uri.to_string())),
            ("diagnostics", Json::Array(diagnostics)),
        ]),
    )
}

fn write_response(writer: &mut impl Write, id: Json, result: Json) -> io::Result<()> {
    write_message(
        writer,
        &json_object_owned(vec![
            (
                "jsonrpc".to_string(),
                Json::String(JSONRPC_VERSION.to_string()),
            ),
            ("id".to_string(), id),
            ("result".to_string(), result),
        ]),
    )
}

fn write_error(writer: &mut impl Write, id: Json, code: i64, message: &str) -> io::Result<()> {
    write_message(
        writer,
        &json_object_owned(vec![
            (
                "jsonrpc".to_string(),
                Json::String(JSONRPC_VERSION.to_string()),
            ),
            ("id".to_string(), id),
            (
                "error".to_string(),
                json_object(vec![
                    ("code", Json::number(code)),
                    ("message", Json::String(message.to_string())),
                ]),
            ),
        ]),
    )
}

fn write_notification(writer: &mut impl Write, method: &str, params: Json) -> io::Result<()> {
    write_message(
        writer,
        &json_object(vec![
            ("jsonrpc", Json::String(JSONRPC_VERSION.to_string())),
            ("method", Json::String(method.to_string())),
            ("params", params),
        ]),
    )
}

fn write_message(writer: &mut impl Write, value: &Json) -> io::Result<()> {
    let payload = value.stringify();
    write!(
        writer,
        "Content-Length: {}\r\n\r\n{}",
        payload.len(),
        payload
    )?;
    writer.flush()
}

fn read_message(reader: &mut impl BufRead) -> io::Result<Option<Vec<u8>>> {
    let mut content_length = None;
    loop {
        let mut line = String::new();
        let read = reader.read_line(&mut line)?;
        if read == 0 {
            return Ok(None);
        }
        let header = line.trim_end_matches(['\r', '\n']);
        if header.is_empty() {
            break;
        }
        if let Some(value) = header.strip_prefix("Content-Length:") {
            content_length = value.trim().parse::<usize>().ok();
        }
    }

    let Some(content_length) = content_length else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "LSP message missing Content-Length header",
        ));
    };
    let mut buf = vec![0; content_length];
    reader.read_exact(&mut buf)?;
    Ok(Some(buf))
}

fn write_parse_error(writer: &mut impl Write, message: &str) -> io::Result<()> {
    write_error(writer, Json::Null, PARSE_ERROR, message)
}

pub fn run_stdio(options: LoadOptions) -> io::Result<()> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    run(stdin.lock(), stdout.lock(), options)
}

fn run(mut reader: impl BufRead, mut writer: impl Write, options: LoadOptions) -> io::Result<()> {
    let mut server = LspServer::new(options);
    while let Some(bytes) = read_message(&mut reader)? {
        let text = match std::str::from_utf8(&bytes) {
            Ok(text) => text,
            Err(err) => {
                write_parse_error(
                    &mut writer,
                    &format!("invalid UTF-8 JSON-RPC message: {}", err),
                )?;
                continue;
            }
        };
        let message = match parse_json(text) {
            Ok(message) => message,
            Err(err) => {
                write_parse_error(&mut writer, &err)?;
                continue;
            }
        };
        if server.handle_message(message, &mut writer)? {
            break;
        }
    }
    Ok(())
}

struct OverlaySource {
    root_path: PathBuf,
    root_canon: PathBuf,
    root_text: String,
}

impl OverlaySource {
    fn new(root_path: &Path, root_text: &str) -> Self {
        let root_path = absolute_path(root_path);
        let root_canon = fs::canonicalize(&root_path).unwrap_or_else(|_| root_path.clone());
        OverlaySource {
            root_path,
            root_canon,
            root_text: root_text.to_string(),
        }
    }

    fn is_root(&self, path: &Path) -> bool {
        let absolute = absolute_path(path);
        absolute == self.root_path || absolute == self.root_canon || path == self.root_canon
    }
}

impl ModuleSource for OverlaySource {
    fn read(&self, path: &Path) -> io::Result<String> {
        if self.is_root(path) {
            Ok(self.root_text.clone())
        } else {
            fs::read_to_string(path)
        }
    }

    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
        if self.is_root(path) {
            return Ok(self.root_canon.clone());
        }
        fs::canonicalize(path)
    }
}

fn absolute_path(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}

fn file_uri_to_path(uri: &str) -> Option<PathBuf> {
    let rest = uri.strip_prefix("file://")?;
    let decoded = percent_decode(rest)?;
    if cfg!(windows) {
        let path = if decoded.as_bytes().first() == Some(&b'/')
            && decoded.as_bytes().get(2) == Some(&b':')
        {
            &decoded[1..]
        } else {
            decoded.as_str()
        };
        Some(PathBuf::from(path.replace('/', "\\")))
    } else if decoded.starts_with('/') {
        Some(PathBuf::from(decoded))
    } else {
        None
    }
}

fn path_to_file_uri(path: &Path) -> String {
    let path = absolute_path(path);
    let text = uri_path_text(&path);
    if cfg!(windows) {
        if let Some(rest) = text.strip_prefix("//") {
            format!("file://{}", percent_encode_path(rest))
        } else {
            format!("file:///{}", percent_encode_path(&text))
        }
    } else if text.starts_with('/') {
        format!("file://{}", percent_encode_path(&text))
    } else {
        format!("file:///{}", percent_encode_path(&text))
    }
}

fn uri_path_text(path: &Path) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    if cfg!(windows) {
        if let Some(rest) = text.strip_prefix("//?/UNC/") {
            format!("//{}", rest)
        } else if let Some(rest) = text.strip_prefix("//?/") {
            rest.to_string()
        } else {
            text
        }
    } else {
        text
    }
}

fn percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hi = hex_value(*bytes.get(i + 1)?)?;
            let lo = hex_value(*bytes.get(i + 2)?)?;
            out.push(hi * 16 + lo);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
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
