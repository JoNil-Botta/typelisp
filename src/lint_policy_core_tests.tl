;; lint_policy_core_tests.tl - Executable coverage for pure lint policy
;; resolution. Main-less companion imported by src/tests/lint_smoke.tl.
(import lint_core)
(import lint_policy_core as policy)
(import stdlib.io)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)

(define (lint-policy-test-expect [condition : bool] [message : String]) : unit
  (unless condition (io.panic message)))

(define (lint-policy-test-kind-code
  [kind : (& kind policy.LintPolicyDiagnosticKind)]) : i64
  (match kind
    [(policy.LintPolicyDiagnosticKind.UnknownRule) 1]
    [(policy.LintPolicyDiagnosticKind.UnknownGroup) 2]
    [(policy.LintPolicyDiagnosticKind.DuplicateGroup) 3]
    [(policy.LintPolicyDiagnosticKind.InvalidGroupReference) 4]
    [(policy.LintPolicyDiagnosticKind.ContradictoryAssignment) 5]
    [(policy.LintPolicyDiagnosticKind.GroupCycle) 6]
    [(policy.LintPolicyDiagnosticKind.ForbidLowering) 7]))

(define (lint-policy-test-outcome-code
  [outcome : (& outcome policy.LintPolicyTraceOutcome)]) : i64
  (match outcome
    [(policy.LintPolicyTraceOutcome.Inactive) 1]
    [(policy.LintPolicyTraceOutcome.Applied) 2]
    [(policy.LintPolicyTraceOutcome.Shadowed) 3]
    [(policy.LintPolicyTraceOutcome.Rejected) 4]))

(define (lint-policy-test-diagnostic-count
  [resolution : (& resolution policy.LintPolicyResolution)]
  [kind-code : i64]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (<
        index
        (policy.lint-policy-diagnostics-count resolution.diagnostics))
        (let
          [diagnostic : policy.LintPolicyDiagnostic
            (policy.lint-policy-diagnostics-ref resolution.diagnostics index)]
          (begin
            (when
              (= (lint-policy-test-kind-code diagnostic.kind) kind-code)
              (set! count (+ count 1)))
            (set! index (+ index 1)))))
      count)))

(define (lint-policy-test-trace-count
  [resolution : (& resolution policy.LintPolicyResolution)]
  [outcome-code : i64]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index (policy.lint-policy-trace-count resolution.trace))
        (let
          [entry : policy.LintPolicyTraceEntry
            (policy.lint-policy-trace-ref resolution.trace index)]
          (begin
            (when
              (= (lint-policy-test-outcome-code entry.outcome) outcome-code)
              (set! count (+ count 1)))
            (set! index (+ index 1)))))
      count)))

(define (lint-policy-test-trace-has-source?
  [resolution : (& resolution policy.LintPolicyResolution)]
  [outcome-code : i64]
  [source : (& source str)]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and
        (not found)
        (< index (policy.lint-policy-trace-count resolution.trace)))
        (let
          [entry : policy.LintPolicyTraceEntry
            (policy.lint-policy-trace-ref resolution.trace index)]
          (begin
            (when
              (and
                (= (lint-policy-test-outcome-code entry.outcome) outcome-code)
                (string.eq entry.origin.source source))
              (set! found true))
            (set! index (+ index 1)))))
      found)))

(define (lint-policy-test-decision-is?
  [resolution : (& resolution policy.LintPolicyResolution)]
  [rule-id : (& rule-id str)]
  [level : lint_core.LintLevel]
  [layer : policy.LintPolicyLayer]
  [source : (& source str)]) : bool
  (match (policy.lint-policy-decision-find resolution rule-id)
    [(policy.LintMaybePolicyDecision.NotFound) false]
    [(policy.LintMaybePolicyDecision.Found decision)
      (and
        (lint_core.lint-level-eq? decision.level level)
        (=
          (policy.lint-policy-layer-rank decision.layer)
          (policy.lint-policy-layer-rank layer))
        (string.eq decision.origin.source source))]))

(define (lint-policy-test-origin [source : String]) : policy.LintPolicyOrigin
  (policy.lint-policy-origin (string.copy source) source))

(define (lint-policy-test-rule-assignment
  [name : String]
  [level : lint_core.LintLevel]
  [layer : policy.LintPolicyLayer]
  [selected : bool]
  [source : String]) : policy.LintPolicyAssignment
  (policy.lint-policy-rule-assignment
    name
    level
    layer
    (policy.LintPolicyAssignmentMode.Exact)
    selected
    (lint-policy-test-origin source)))

(define (lint-policy-test-group-assignment
  [name : String]
  [level : lint_core.LintLevel]
  [layer : policy.LintPolicyLayer]
  [selected : bool]
  [source : String]) : policy.LintPolicyAssignment
  (policy.lint-policy-group-assignment
    name
    level
    layer
    (policy.LintPolicyAssignmentMode.Exact)
    selected
    (lint-policy-test-origin source)))

(define (lint-policy-test-group
  [name : String]
  [members : policy.LintPolicyGroupMembers]
  [source : String]) : policy.LintPolicyGroup
  (policy.LintPolicyGroup
    name
    members
    (policy.LintPolicyLayer.Project)
    (lint-policy-test-origin source)))

(define (lint-policy-test-registry-and-defaults) : unit
  (let
    [rules : lint_core.LintRuleList (lint_core.lint-rule-registry)]
    [resolution : policy.LintPolicyResolution (policy.lint-policy-default)]
    [deprecated-default : lint_core.LintLevel
      (lint_core.lint-rule-default-level
        (lint_core.lint-rule-deprecated-string-concat-id))]
    [nested-let-default : lint_core.LintLevel
      (lint_core.lint-rule-default-level (lint_core.lint-rule-nested-let-id))]
    [index : i64 0]
    (begin
      (lint-policy-test-expect
        (= (lint_core.lint-rule-list-count rules) 27)
        "lint policy: registry count should remain deterministic")
      (while (< index (lint_core.lint-rule-list-count rules))
        (let
          [rule : lint_core.LintRule (lint_core.lint-rule-list-ref rules index)]
          (begin
            (lint-policy-test-expect
              (> rule.group-mask 0)
              "lint policy: every registered rule needs a built-in group")
            (set! index (+ index 1)))))
      (lint-policy-test-expect
        (string.eq
          (lint_core.lint-rule-list-ref rules 0).rule-id
          (lint_core.lint-rule-nested-if-ladder-id))
        "lint policy: first registry decision should be stable")
      (lint-policy-test-expect
        (string.eq
          (lint_core.lint-rule-list-ref rules 26).rule-id
          (lint_core.lint-rule-type-name-case-id))
        "lint policy: last registry decision should be stable")
      (lint-policy-test-expect
        (= (lint_core.lint-level-rank deprecated-default) 0)
        "lint policy: opt-in compatibility lint should default to allow")
      (lint-policy-test-expect
        (= (lint_core.lint-level-rank nested-let-default) 1)
        "lint policy: existing default lint should remain warn")
      (lint-policy-test-expect
        (and
          (= resolution.stats.registry-rules 27)
          (= resolution.stats.group-definitions 0)
          (= resolution.stats.group-members 0)
          (= resolution.stats.assignments 0)
          (= resolution.stats.expanded-rule-updates 0)
          (= resolution.stats.trace-entries 0)
          (= (policy.lint-policy-decisions-count resolution.decisions) 27)
          (= (policy.lint-policy-resolution-diagnostics-count resolution) 0)
          (= (policy.lint-policy-resolution-trace-count resolution) 0))
        "lint policy: disabled policy work must be one fixed registry pass"))))

(define (lint-policy-test-same-layer-order) : unit
  (let
    [resolution : policy.LintPolicyResolution
      (policy.lint-policy-resolve
        (policy.lint-policy-groups-empty)
        (policy.lint-policy-assignments-from
          (__tl_make-array
            (lint-policy-test-group-assignment
              "style"
              (lint_core.LintLevel.Deny)
              (policy.LintPolicyLayer.Project)
              true
              "project-group")
            (lint-policy-test-rule-assignment
              (lint_core.lint-rule-nested-let-id)
              (lint_core.LintLevel.Warn)
              (policy.LintPolicyLayer.Project)
              true
              "project-rule"))))]
    (begin
      (lint-policy-test-expect
        (lint-policy-test-decision-is?
          resolution
          "nested-let"
          (lint_core.LintLevel.Warn)
          (policy.LintPolicyLayer.Project)
          "project-rule")
        "lint policy: a rule assignment must override its group in one layer")
      (lint-policy-test-expect
        (= (policy.lint-policy-resolution-diagnostics-count resolution) 0)
        "lint policy: group/rule layering should not diagnose a conflict"))))

(define (lint-policy-test-scope-and-cfg-precedence) : unit
  (let
    [resolution : policy.LintPolicyResolution
      (policy.lint-policy-resolve
        (policy.lint-policy-groups-empty)
        (policy.lint-policy-assignments-from
          (__tl_make-array
            (lint-policy-test-rule-assignment
              "nested-let"
              (lint_core.LintLevel.Warn)
              (policy.LintPolicyLayer.Project)
              true
              "project")
            (lint-policy-test-rule-assignment
              "nested-let"
              (lint_core.LintLevel.Deny)
              (policy.LintPolicyLayer.TargetProfile)
              true
              "selected-target")
            (lint-policy-test-rule-assignment
              "nested-let"
              (lint_core.LintLevel.Forbid)
              (policy.LintPolicyLayer.Cli)
              false
              "cfg-disabled")
            (lint-policy-test-rule-assignment
              "nested-let"
              (lint_core.LintLevel.Deny)
              (policy.LintPolicyLayer.ModuleItem)
              true
              "module")
            (lint-policy-test-rule-assignment
              "nested-let"
              (lint_core.LintLevel.Allow)
              (policy.LintPolicyLayer.Local)
              true
              "local"))))]
    (begin
      (lint-policy-test-expect
        (lint-policy-test-decision-is?
          resolution
          "nested-let"
          (lint_core.LintLevel.Allow)
          (policy.LintPolicyLayer.Local)
          "local")
        "lint policy: local assignment must win the documented scope order")
      (lint-policy-test-expect
        (lint-policy-test-trace-has-source? resolution 1 "cfg-disabled")
        "lint policy: unselected cfg input must remain visible as inactive")
      (lint-policy-test-expect
        (= (policy.lint-policy-resolution-trace-count resolution) 5)
        "lint policy: every selected and inactive rule assignment needs trace"))))

(define (lint-policy-test-forbid) : unit
  (let
    [resolution : policy.LintPolicyResolution
      (policy.lint-policy-resolve
        (policy.lint-policy-groups-empty)
        (policy.lint-policy-assignments-from
          (__tl_make-array
            (lint-policy-test-rule-assignment
              "nested-let"
              (lint_core.LintLevel.Forbid)
              (policy.LintPolicyLayer.Project)
              true
              "project-forbid")
            (lint-policy-test-rule-assignment
              "nested-let"
              (lint_core.LintLevel.Allow)
              (policy.LintPolicyLayer.Local)
              true
              "local-allow"))))]
    (begin
      (lint-policy-test-expect
        (lint-policy-test-decision-is?
          resolution
          "nested-let"
          (lint_core.LintLevel.Forbid)
          (policy.LintPolicyLayer.Project)
          "project-forbid")
        "lint policy: forbid must not be lowered")
      (lint-policy-test-expect
        (= (lint-policy-test-diagnostic-count resolution 7) 1)
        "lint policy: forbid lowering needs one structured diagnostic")
      (lint-policy-test-expect
        (= (lint-policy-test-trace-count resolution 4) 1)
        "lint policy: rejected forbid lowering must remain in the trace"))))

(define (lint-policy-test-invalid-inputs) : unit
  (let
    [unknown : policy.LintPolicyResolution
      (policy.lint-policy-resolve
        (policy.lint-policy-groups-empty)
        (policy.lint-policy-assignments-from
          (__tl_make-array
            (lint-policy-test-rule-assignment
              "not-a-rule"
              (lint_core.LintLevel.Deny)
              (policy.LintPolicyLayer.Project)
              true
              "unknown-rule")
            (lint-policy-test-group-assignment
              "not-a-group"
              (lint_core.LintLevel.Deny)
              (policy.LintPolicyLayer.Project)
              true
              "unknown-group"))))]
    [contradictory : policy.LintPolicyResolution
      (policy.lint-policy-resolve
        (policy.lint-policy-groups-empty)
        (policy.lint-policy-assignments-from
          (__tl_make-array
            (lint-policy-test-rule-assignment
              "nested-let"
              (lint_core.LintLevel.Warn)
              (policy.LintPolicyLayer.Project)
              true
              "duplicate-a")
            (lint-policy-test-rule-assignment
              "nested-let"
              (lint_core.LintLevel.Deny)
              (policy.LintPolicyLayer.Project)
              true
              "duplicate-b"))))]
    [duplicate-group : policy.LintPolicyResolution
      (policy.lint-policy-resolve
        (policy.lint-policy-groups-from
          (__tl_make-array
            (lint-policy-test-group
              "same-group"
              (policy.lint-policy-group-members-empty)
              "group-a")
            (lint-policy-test-group
              "same-group"
              (policy.lint-policy-group-members-empty)
              "group-b")))
        (policy.lint-policy-assignments-empty))]
    (begin
      (lint-policy-test-expect
        (and
          (= (lint-policy-test-diagnostic-count unknown 1) 1)
          (= (lint-policy-test-diagnostic-count unknown 2) 1)
          (= (lint-policy-test-trace-count unknown 4) 2))
        "lint policy: unknown rules and groups need diagnostics and rejected trace")
      (lint-policy-test-expect
        (= (lint-policy-test-diagnostic-count contradictory 5) 1)
        "lint policy: contradictory same-layer assignments need a diagnostic")
      (lint-policy-test-expect
        (= (lint-policy-test-diagnostic-count duplicate-group 3) 1)
        "lint policy: duplicate custom group names need a diagnostic")
      (lint-policy-test-expect
        (lint-policy-test-decision-is?
          contradictory
          "nested-let"
          (lint_core.LintLevel.Deny)
          (policy.LintPolicyLayer.Project)
          "duplicate-b")
        "lint policy: contradictory input must still resolve deterministically"))))

(define (lint-policy-test-custom-groups) : unit
  (let
    [groups : policy.LintPolicyGroups
      (policy.lint-policy-groups-from
        (__tl_make-array
          (lint-policy-test-group
            "style-leaf"
            (policy.lint-policy-group-members-from
              (__tl_make-array (policy.LintPolicyGroupMember.Group "style")))
            "leaf")
          (lint-policy-test-group
            "project-strict"
            (policy.lint-policy-group-members-from
              (__tl_make-array
                (policy.LintPolicyGroupMember.Group "style-leaf")
                (policy.LintPolicyGroupMember.Rule "no-effect")))
            "parent")))]
    [resolution : policy.LintPolicyResolution
      (policy.lint-policy-resolve
        groups
        (policy.lint-policy-assignments-from
          (__tl_make-array
            (lint-policy-test-group-assignment
              "project-strict"
              (lint_core.LintLevel.Deny)
              (policy.LintPolicyLayer.Project)
              true
              "strict-assignment"))))]
    (begin
      (lint-policy-test-expect
        (= (policy.lint-policy-resolution-diagnostics-count resolution) 0)
        "lint policy: valid nested groups should resolve cleanly")
      (lint-policy-test-expect
        (and
          (lint-policy-test-decision-is?
            resolution
            "nested-let"
            (lint_core.LintLevel.Deny)
            (policy.LintPolicyLayer.Project)
            "strict-assignment")
          (lint-policy-test-decision-is?
            resolution
            "no-effect"
            (lint_core.LintLevel.Deny)
            (policy.LintPolicyLayer.Project)
            "strict-assignment"))
        "lint policy: nested custom groups must expand built-in groups and rules")
      (lint-policy-test-expect
        (and
          (= resolution.stats.group-definitions 2)
          (= resolution.stats.group-members 3)
          (= resolution.stats.assignments 1)
          (=
            resolution.stats.expanded-rule-updates
            resolution.stats.trace-entries))
        "lint policy: custom group work census must match the expansion trace"))))

(define (lint-policy-test-group-cycle) : unit
  (let
    [groups : policy.LintPolicyGroups
      (policy.lint-policy-groups-from
        (__tl_make-array
          (lint-policy-test-group
            "cycle-a"
            (policy.lint-policy-group-members-from
              (__tl_make-array (policy.LintPolicyGroupMember.Group "cycle-b")))
            "cycle-a")
          (lint-policy-test-group
            "cycle-b"
            (policy.lint-policy-group-members-from
              (__tl_make-array (policy.LintPolicyGroupMember.Group "cycle-a")))
            "cycle-b")))]
    [resolution : policy.LintPolicyResolution
      (policy.lint-policy-resolve
        groups
        (policy.lint-policy-assignments-from
          (__tl_make-array
            (lint-policy-test-group-assignment
              "cycle-a"
              (lint_core.LintLevel.Deny)
              (policy.LintPolicyLayer.Project)
              true
              "cycle-assignment"))))]
    (begin
      (lint-policy-test-expect
        (>= (lint-policy-test-diagnostic-count resolution 6) 1)
        "lint policy: custom group cycles need a structured diagnostic")
      (lint-policy-test-expect
        (= resolution.stats.expanded-rule-updates 0)
        "lint policy: invalid cyclic groups must not affect rules")
      (lint-policy-test-expect
        (= (lint-policy-test-trace-count resolution 4) 1)
        "lint policy: assignment to a cyclic group must be rejected"))))

(define (lint-policy-test-chain-groups [count : i64]) : policy.LintPolicyGroups
  (let
    [slots : (__tl_dyn-array policy.LintPolicyGroup)
      (__tl_make-array policy.LintPolicyGroup count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [name : String (str_cat.str-cat "chain-" (string.int->string index))]
          [member-name : String
            (if (= index (- count 1))
              "style"
              (str_cat.str-cat "chain-" (string.int->string (+ index 1))))]
          (begin
            (set!
              (array-ref slots index)
              (lint-policy-test-group
                name
                (policy.lint-policy-group-members-from
                  (__tl_make-array
                    (policy.LintPolicyGroupMember.Group member-name)))
                "linear-chain"))
            (set! index (+ index 1)))))
      (policy.lint-policy-groups-from slots))))

(define (lint-policy-test-linear-chain) : unit
  (let
    [resolution : policy.LintPolicyResolution
      (policy.lint-policy-resolve
        (lint-policy-test-chain-groups 64)
        (policy.lint-policy-assignments-from
          (__tl_make-array
            (lint-policy-test-group-assignment
              "chain-0"
              (lint_core.LintLevel.Deny)
              (policy.LintPolicyLayer.Project)
              true
              "chain-assignment"))))]
    (begin
      (lint-policy-test-expect
        (= (policy.lint-policy-resolution-diagnostics-count resolution) 0)
        "lint policy: a deep acyclic group chain should remain valid")
      (lint-policy-test-expect
        (lint-policy-test-decision-is?
          resolution
          "nested-let"
          (lint_core.LintLevel.Deny)
          (policy.LintPolicyLayer.Project)
          "chain-assignment")
        "lint policy: memoized deep group expansion should reach built-in rules")
      (lint-policy-test-expect
        (and
          (= resolution.stats.group-definitions 64)
          (= resolution.stats.group-members 64)
          (= resolution.stats.assignments 1)
          (=
            resolution.stats.expanded-rule-updates
            resolution.stats.trace-entries))
        "lint policy: deep-chain work accounting should stay declaration-linear"))))

(define (lint-policy-test-minimum-and-legacy) : unit
  (let
    [floor-resolution : policy.LintPolicyResolution
      (policy.lint-policy-resolve
        (policy.lint-policy-groups-empty)
        (policy.lint-policy-assignments-from
          (__tl_make-array
            (lint-policy-test-rule-assignment
              "nested-let"
              (lint_core.LintLevel.Deny)
              (policy.LintPolicyLayer.Project)
              true
              "project-deny")
            (policy.lint-policy-rule-assignment
              "nested-let"
              (lint_core.LintLevel.Warn)
              (policy.LintPolicyLayer.Cli)
              (policy.LintPolicyAssignmentMode.Minimum)
              true
              (lint-policy-test-origin "legacy-floor")))))]
    [legacy : policy.LintPolicyResolution
      (policy.lint-policy-legacy-resolution true true false true)]
    [dotted-only : policy.LintPolicyResolution
      (policy.lint-policy-legacy-resolution false false true false)]
    (begin
      (lint-policy-test-expect
        (lint-policy-test-decision-is?
          floor-resolution
          "nested-let"
          (lint_core.LintLevel.Deny)
          (policy.LintPolicyLayer.Project)
          "project-deny")
        "lint policy: a legacy warn floor must not lower project deny")
      (lint-policy-test-expect
        (= (lint-policy-test-trace-count floor-resolution 3) 1)
        "lint policy: satisfied minimum should be recorded as shadowed")
      (lint-policy-test-expect
        (and
          (= legacy.stats.assignments 6)
          (= legacy.stats.trace-entries 6)
          (lint-policy-test-decision-is?
            legacy
            "deprecated-string-concat"
            (lint_core.LintLevel.Warn)
            (policy.LintPolicyLayer.Cli)
            "legacy-cli")
          (lint-policy-test-decision-is?
            legacy
            "global-name-case"
            (lint_core.LintLevel.Warn)
            (policy.LintPolicyLayer.Cli)
            "legacy-cli")
          (lint-policy-test-decision-is?
            legacy
            "type-name-case"
            (lint_core.LintLevel.Warn)
            (policy.LintPolicyLayer.Cli)
            "legacy-cli"))
        "lint policy: legacy flags must expand to monotonic warn floors")
      (lint-policy-test-expect
        (and
          (= dotted-only.stats.assignments 0)
          (= dotted-only.stats.trace-entries 0))
        "lint policy: removed dotted-field flag must remain a compatibility no-op"))))

(define (lint-policy-test-resolved-finding) : unit
  (let
    [resolution : policy.LintPolicyResolution
      (policy.lint-policy-resolve
        (policy.lint-policy-groups-empty)
        (policy.lint-policy-assignments-from
          (__tl_make-array
            (lint-policy-test-rule-assignment
              "nested-let"
              (lint_core.LintLevel.Deny)
              (policy.LintPolicyLayer.Project)
              true
              "finding-policy"))))]
    [resolved : policy.LintPolicyResolvedFinding
      (policy.lint-policy-resolve-finding
        resolution
        (lint_core.LintFinding
          "nested let"
          "nested-let"
          2
          (lint_core.lint-no-span)))]
    (lint-policy-test-expect
      (and
        (string.eq resolved.finding.rule-id "nested-let")
        (= resolved.finding.depth 2)
        (= (lint_core.lint-level-rank resolved.decision.level) 2)
        (string.eq resolved.decision.origin.source "finding-policy")
        (policy.lint-policy-resolved-finding-enabled? resolved))
      "lint policy: resolved findings must carry effective level and origin")))

(define (compiler-lint-policy-self-test) : i64
  (begin
    (lint-policy-test-registry-and-defaults)
    (lint-policy-test-same-layer-order)
    (lint-policy-test-scope-and-cfg-precedence)
    (lint-policy-test-forbid)
    (lint-policy-test-invalid-inputs)
    (lint-policy-test-custom-groups)
    (lint-policy-test-group-cycle)
    (lint-policy-test-linear-chain)
    (lint-policy-test-minimum-and-legacy)
    (lint-policy-test-resolved-finding)
    42))

(test
  lint-policy-resolution
  (unless
    (= (compiler-lint-policy-self-test) 42)
    (io.panic "lint policy: focused self-test failed")))