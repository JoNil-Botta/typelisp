use rand::distributions::{Distribution, WeightedIndex};
use serde_json::Value;
use std::fmt;
use std::io::{self, Read};
use std::process;

const REVIEW_WEIGHT: u32 = 10;
const IMPLEMENT_WEIGHT: u32 = 10;
const RESEARCH_WEIGHT: u32 = 1;
const PRIORITY_BONUS: u32 = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Pr,
    Ready,
    Triage,
}

impl Kind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Pr => "pr",
            Self::Ready => "ready",
            Self::Triage => "triage",
        }
    }
}

impl fmt::Display for Kind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Candidate {
    kind: Kind,
    number: u64,
    labels: Vec<String>,
    title: String,
}

impl Candidate {
    fn priority(&self) -> bool {
        self.labels
            .iter()
            .any(|label| label == "p0" || label == "p1")
    }

    fn github_kind(&self) -> &'static str {
        match self.kind {
            Kind::Pr => "pr",
            Kind::Ready | Kind::Triage => "issue",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Selection {
    selected_item_index: usize,
}

fn read_stdin() -> Result<String, String> {
    let mut text = String::new();
    io::stdin()
        .read_to_string(&mut text)
        .map_err(|err| format!("read stdin: {}", err))?;
    Ok(text)
}

fn parse_combined_json(text: &str) -> Result<(Vec<Value>, Vec<Value>), String> {
    let value =
        serde_json::from_str::<Value>(text).map_err(|err| format!("invalid JSON: {}", err))?;
    let object = value
        .as_object()
        .ok_or_else(|| "expected a JSON object with prs and issues arrays".to_string())?;
    let prs = object
        .get("prs")
        .and_then(Value::as_array)
        .ok_or_else(|| "expected 'prs' to be a JSON array".to_string())?
        .clone();
    let issues = object
        .get("issues")
        .and_then(Value::as_array)
        .ok_or_else(|| "expected 'issues' to be a JSON array".to_string())?
        .clone();
    Ok((prs, issues))
}

fn load_prs_and_issues() -> Result<(Vec<Value>, Vec<Value>), String> {
    parse_combined_json(&read_stdin()?)
}

fn field_u64(item: &Value, field: &str) -> Result<u64, String> {
    item.get(field)
        .and_then(Value::as_u64)
        .ok_or_else(|| format!("candidate missing numeric '{}': {}", field, item))
}

fn field_string(item: &Value, field: &str) -> Result<String, String> {
    item.get(field)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| format!("candidate missing string '{}': {}", field, item))
}

fn labels(item: &Value) -> Result<Vec<String>, String> {
    let Some(raw_labels) = item.get("labels") else {
        return Ok(Vec::new());
    };
    let Some(label_array) = raw_labels.as_array() else {
        return Err(format!("issue labels must be an array: {}", item));
    };

    let mut labels = Vec::new();
    for label in label_array {
        let name = label
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| format!("issue label missing name: {}", label))?;
        labels.push(name.to_string());
    }
    Ok(labels)
}

fn has_label(labels: &[String], needle: &str) -> bool {
    labels.iter().any(|label| label == needle)
}

fn candidates_from_prs(items: Vec<Value>) -> Result<Vec<Candidate>, String> {
    items
        .iter()
        .map(|item| {
            Ok(Candidate {
                kind: Kind::Pr,
                number: field_u64(item, "number")?,
                labels: Vec::new(),
                title: field_string(item, "title")?,
            })
        })
        .collect()
}

fn candidates_from_issues(items: Vec<Value>) -> Result<Vec<Candidate>, String> {
    let mut candidates = Vec::new();

    for item in &items {
        let labels = labels(item)?;
        let kind = if has_label(&labels, "ready-for-implementation") {
            Some(Kind::Ready)
        } else if has_label(&labels, "needs-research") || labels.is_empty() {
            Some(Kind::Triage)
        } else {
            None
        };

        if let Some(kind) = kind {
            candidates.push(Candidate {
                kind,
                number: field_u64(item, "number")?,
                labels,
                title: field_string(item, "title")?,
            });
        }
    }

    Ok(candidates)
}

fn candidate_weight(candidate: &Candidate) -> u32 {
    let base = match candidate.kind {
        Kind::Pr => REVIEW_WEIGHT,
        Kind::Ready => IMPLEMENT_WEIGHT,
        Kind::Triage => RESEARCH_WEIGHT,
    };
    base + if candidate.priority() {
        PRIORITY_BONUS
    } else {
        0
    }
}

fn weighted_index(weights: &[u32]) -> Result<WeightedIndex<u32>, String> {
    WeightedIndex::new(weights).map_err(|err| format!("invalid weights: {}", err))
}

fn choose(candidates: &[Candidate]) -> Result<Selection, String> {
    if candidates.is_empty() {
        return Err("no eligible candidates were provided".into());
    }

    let mut rng = rand::thread_rng();
    let candidate_weights = candidates.iter().map(candidate_weight).collect::<Vec<_>>();
    let selected_item_index = weighted_index(&candidate_weights)?.sample(&mut rng);

    Ok(Selection {
        selected_item_index,
    })
}

fn action_name(kind: Kind) -> &'static str {
    match kind {
        Kind::Pr => "review",
        Kind::Ready => "implement",
        Kind::Triage => "research/triage",
    }
}

fn print_summary(candidates: &[Candidate], selection: &Selection) {
    let selected = &candidates[selection.selected_item_index];

    println!(
        "{} {} #{}: {}",
        action_name(selected.kind),
        selected.github_kind(),
        selected.number,
        selected.title
    );
}

fn run() -> Result<(), String> {
    let (prs, issues) = load_prs_and_issues()?;

    let mut candidates = Vec::new();
    candidates.extend(candidates_from_prs(prs)?);
    candidates.extend(candidates_from_issues(issues)?);

    let selection = choose(&candidates)?;
    print_summary(&candidates, &selection);
    Ok(())
}

fn main() {
    if let Err(err) = run() {
        eprintln!("Error: {}", err);
        process::exit(1);
    }
}
