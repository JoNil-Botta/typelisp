---
name: Bug report
about: Report a compiler crash, wrong output, or unexpected behavior
labels: bug
---

**Describe the bug**
A clear and concise description.

**To Reproduce**
Minimal `.tl` file that triggers the bug:

```lisp
;; paste code here
```

**Expected behavior**
What should happen.

**Actual behavior**
What actually happens. Include full compiler output.

**Selfhost implementation target**
If this affects compiler, tooling, runtime, or stdlib behavior, where should the
TypeLisp-owned fix or regression fixture live? Prefer `selfhost/...` or
`stdlib/...`. If Rust must change temporarily, link the no-Rust migration issue.

**Environment**
- OS:
- TypeLisp version (`typelisp --version`, if available):
- TypeLisp commit/branch:
