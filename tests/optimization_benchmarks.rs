use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn optimization_benchmark_manifest_and_tl_sources_compile() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let manifest = root
        .join("benchmarks")
        .join("optimization")
        .join("cases.tsv");
    let manifest_text =
        fs::read_to_string(&manifest).expect("read optimization benchmark manifest");
    let work_dir = root
        .join("target")
        .join("optimization-benchmark-smoke-test");
    let _ = fs::remove_dir_all(&work_dir);
    fs::create_dir_all(&work_dir).expect("create optimization benchmark smoke work dir");

    let mut seen = BTreeSet::new();
    let mut case_count = 0usize;

    for (line_index, raw_line) in manifest_text.lines().enumerate() {
        let line_no = line_index + 1;
        let line = raw_line.trim_end();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        let fields: Vec<&str> = line.split('|').collect();
        assert_eq!(
            fields.len(),
            3,
            "manifest line {line_no} must have name|category|args: {line}"
        );
        let name = fields[0];
        let category = fields[1];
        let args = fields[2];
        assert!(
            !name.is_empty() && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'),
            "manifest line {line_no} has invalid case name: {name}"
        );
        assert!(
            !category.is_empty()
                && category
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-'),
            "manifest line {line_no} has invalid category: {category}"
        );
        assert!(
            !args.trim().is_empty(),
            "manifest line {line_no} must include benchmark args"
        );
        assert!(
            seen.insert(name.to_string()),
            "duplicate benchmark case: {name}"
        );

        let tl_source = root
            .join("benchmarks")
            .join("optimization")
            .join("tl")
            .join(format!("{name}.tl"));
        let c_source = root
            .join("benchmarks")
            .join("optimization")
            .join("c")
            .join(format!("{name}.c"));
        assert!(tl_source.is_file(), "missing TypeLisp source for {name}");
        assert!(c_source.is_file(), "missing C source for {name}");

        let c_text = fs::read_to_string(&c_source).expect("read C benchmark source");
        assert!(
            c_text.contains("int main("),
            "C benchmark {name} must define main"
        );

        let asm_path = work_dir.join(format!("{name}.s"));
        let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
            .arg("compile")
            .arg(&tl_source)
            .arg("-o")
            .arg(&asm_path)
            .output()
            .expect("run typelisp compile for benchmark source");
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            output.status.success(),
            "TypeLisp benchmark {name} failed to compile\nstdout:\n{stdout}\nstderr:\n{stderr}"
        );

        let asm = fs::read_to_string(&asm_path).expect("read generated benchmark assembly");
        assert!(
            !asm.contains("# TODO"),
            "benchmark {name} assembly still contains a backend TODO:\n{asm}"
        );
        assert!(
            asm.contains("\nmain:") || asm.starts_with("main:"),
            "benchmark {name} assembly must define main:\n{asm}"
        );

        case_count += 1;
    }

    assert!(
        case_count >= 11,
        "expected optimization benchmark cases, including runtime helper coverage"
    );

    let runner = fs::read_to_string(root.join("scripts").join("run-optimization-benchmarks.sh"))
        .expect("read optimization benchmark runner");
    assert!(
        runner.contains("TYPELISP_BENCH_SELFHOST")
            && runner.contains("case,category,tl_ms,c_ms,ratio"),
        "runner must expose the documented local benchmark controls and CSV report"
    );
    assert!(
        runner.contains("\"$FILTER\"*"),
        "runner must support prefix filtering for grouped benchmark cases"
    );
}
