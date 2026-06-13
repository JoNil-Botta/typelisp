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
TypeLisp-owned fix or regression fixture live? Prefer `src/...` or
`stdlib/...`. If a non-TypeLisp implementation-language exception seems
necessary, link the tracking issue and explain why it cannot stay in the
selfhost or stdlib code.

**Environment**
- OS:
- TypeLisp binary/stage0 tag:
- TypeLisp commit/branch:
