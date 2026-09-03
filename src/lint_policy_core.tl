;# lint_policy_core.tl - Pure deterministic lint policy resolution.
;#
;# This module consumes typed group and assignment values. It deliberately does
;# not parse typelisp.pkg, inspect the environment, read files, or render
;# diagnostics. Registry order is the canonical output order. Precedence is:
;# built-in defaults, project, target/profile, CLI, module/item, then local.
;# Within one layer, group assignments run in input order before individual
;# rule assignments; an individual rule therefore wins over a group. Exact
;# assignments may raise or lower ordinary levels, but no assignment can lower
;# an effective `forbid`. Minimum assignments are monotonic floors used by the
;# legacy CLI adapter.
;#
;# One hashed group index, one three-color dependency walk, and memoized
;# group/rule membership keep resolution O(G + M + A) for G group declarations,
;# M group members, and A assignments with the fixed registry. Finding lookup
;# is O(F) with the fixed 27-rule decision table.
(import compiler_owned_view as owned_view)
(import lint_core)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as lint_policy_string_i64_map)
(import stdlib.string)

(defenum LintPolicyLayer
  (Builtin)
  (Project)
  (TargetProfile)
  (Cli)
  (ModuleItem)
  (Local))

(define (lint-policy-layer-rank [layer : (& layer LintPolicyLayer)]) : i64
  (match layer
    [(LintPolicyLayer.Builtin) 0]
    [(LintPolicyLayer.Project) 1]
    [(LintPolicyLayer.TargetProfile) 2]
    [(LintPolicyLayer.Cli) 3]
    [(LintPolicyLayer.ModuleItem) 4]
    [(LintPolicyLayer.Local) 5]))

(define (lint-policy-layer-name [layer : LintPolicyLayer]) : String
  (match layer
    [(LintPolicyLayer.Builtin) "built-in"]
    [(LintPolicyLayer.Project) "project"]
    [(LintPolicyLayer.TargetProfile) "target/profile"]
    [(LintPolicyLayer.Cli) "cli"]
    [(LintPolicyLayer.ModuleItem) "module/item"]
    [(LintPolicyLayer.Local) "local"]))

(defenum LintPolicyAssignmentMode
  (Exact)
  (Minimum))

(defenum LintPolicySubject
  (Rule String)
  (Group String))

(define (lint-policy-subject-name [subject : (& subject LintPolicySubject)]) : String
  (match subject
    [(LintPolicySubject.Rule name) (string.copy name)]
    [(LintPolicySubject.Group name) (string.copy name)]))

(define (lint-policy-subject-is-rule? [subject : (& subject LintPolicySubject)]) : bool
  (match subject
    [(LintPolicySubject.Rule _) true]
    [_ false]))

;: Parser-neutral source origin retained verbatim through policy resolution.
;: Configuration adapters may populate the path/span fields; synthetic legacy
;: CLI inputs use zero coordinates and a descriptive `source`/`reason`.
(defstruct LintPolicyOrigin
  (source String)
  (path String)
  (start-line i64)
  (start-column i64)
  (end-line i64)
  (end-column i64)
  (reason String))

(define (lint-policy-origin [source : String] [reason : String]) : LintPolicyOrigin
  (LintPolicyOrigin source "" 0 0 0 0 reason))

(define (lint-policy-built-in-origin) : LintPolicyOrigin
  (lint-policy-origin "registry" "registry default"))

(defstruct LintPolicyAssignment
  (subject LintPolicySubject)
  (level lint_core.LintLevel)
  (layer LintPolicyLayer)
  (mode LintPolicyAssignmentMode)
  (selected bool)
  (origin LintPolicyOrigin))

(defstruct LintPolicyAssignments
  (slots (__tl_dyn-array LintPolicyAssignment))
  (len i64))

(define (lint-policy-assignments-empty) : LintPolicyAssignments
  (LintPolicyAssignments (__tl_make-array LintPolicyAssignment 0) 0))

(define (lint-policy-assignments-from
  [slots : (__tl_dyn-array LintPolicyAssignment)]) : LintPolicyAssignments
  (let
    [len : i64 (array-length slots)]
    (LintPolicyAssignments slots len)))

(define (lint-policy-assignments-count
  [items : (& items LintPolicyAssignments)]) : i64
  items.len)

(define (lint-policy-assignments-ref
  [items : (& items LintPolicyAssignments)]
  [index : i64]) : LintPolicyAssignment
  (owned_view.compiler-owned-array-element-shared-view items.slots index))

(defenum LintPolicyGroupMember
  (Rule String)
  (Group String))

(defstruct LintPolicyGroupMembers
  (slots (__tl_dyn-array LintPolicyGroupMember))
  (len i64))

(define (lint-policy-group-members-empty) : LintPolicyGroupMembers
  (LintPolicyGroupMembers (__tl_make-array LintPolicyGroupMember 0) 0))

(define (lint-policy-group-members-from
  [slots : (__tl_dyn-array LintPolicyGroupMember)]) : LintPolicyGroupMembers
  (let
    [len : i64 (array-length slots)]
    (LintPolicyGroupMembers slots len)))

(define (lint-policy-group-members-ref
  [items : (& items LintPolicyGroupMembers)]
  [index : i64]) : LintPolicyGroupMember
  (owned_view.compiler-owned-array-element-shared-view items.slots index))

(defstruct LintPolicyGroup
  (name String)
  (members LintPolicyGroupMembers)
  (layer LintPolicyLayer)
  (origin LintPolicyOrigin))

(defstruct LintPolicyGroups
  (slots (__tl_dyn-array LintPolicyGroup))
  (len i64))

(define (lint-policy-groups-empty) : LintPolicyGroups
  (LintPolicyGroups (__tl_make-array LintPolicyGroup 0) 0))

(define (lint-policy-groups-from [slots : (__tl_dyn-array LintPolicyGroup)]) : LintPolicyGroups
  (let
    [len : i64 (array-length slots)]
    (LintPolicyGroups slots len)))

(define (lint-policy-groups-count [items : (& items LintPolicyGroups)]) : i64
  items.len)

(define (lint-policy-groups-ref
  [items : (& items LintPolicyGroups)]
  [index : i64]) : LintPolicyGroup
  (owned_view.compiler-owned-array-element-shared-view items.slots index))

(defenum LintPolicyDiagnosticKind
  (UnknownRule)
  (UnknownGroup)
  (DuplicateGroup)
  (InvalidGroupReference)
  (ContradictoryAssignment)
  (GroupCycle)
  (ForbidLowering))

(defstruct LintPolicyDiagnostic
  (kind LintPolicyDiagnosticKind)
  (subject String)
  (layer LintPolicyLayer)
  (origin LintPolicyOrigin)
  (message String))

(defstruct LintPolicyDiagnostics
  (slots (__tl_dyn-array LintPolicyDiagnostic))
  (len i64))

(define (lint-policy-diagnostics-with-capacity [capacity : i64]) : LintPolicyDiagnostics
  (LintPolicyDiagnostics
    (__tl_make-array
      LintPolicyDiagnostic
      (if (< capacity 1)
        1
        capacity))
    0))

(define (lint-policy-diagnostics-count
  [items : (& items LintPolicyDiagnostics)]) : i64
  items.len)

(define (lint-policy-diagnostics-ref
  [items : (& items LintPolicyDiagnostics)]
  [index : i64]) : LintPolicyDiagnostic
  (owned_view.compiler-owned-array-element-shared-view items.slots index))

(define (lint-policy-diagnostics-add
  [items : LintPolicyDiagnostics]
  [diagnostic : LintPolicyDiagnostic]) : LintPolicyDiagnostics
  (begin
    (set! (array-ref items.slots items.len) diagnostic)
    (LintPolicyDiagnostics items.slots (+ items.len 1))))

(defstruct LintPolicyDecision
  (rule-id String)
  (level lint_core.LintLevel)
  (layer LintPolicyLayer)
  (assignment-index i64)
  (origin LintPolicyOrigin))

(defstruct LintPolicyDecisions
  (slots (__tl_dyn-array LintPolicyDecision))
  (len i64))

(define (lint-policy-decisions-count [items : (& items LintPolicyDecisions)]) : i64
  items.len)

(define (lint-policy-decisions-ref
  [items : (& items LintPolicyDecisions)]
  [index : i64]) : LintPolicyDecision
  (owned_view.compiler-owned-array-element-shared-view items.slots index))

(defenum LintMaybePolicyDecision
  (NotFound)
  (Found LintPolicyDecision))

(defenum LintPolicyTraceOutcome
  (Inactive)
  (Applied)
  (Shadowed)
  (Rejected))

(defstruct LintPolicyTraceEntry
  (assignment-index i64)
  (rule-id String)
  (layer LintPolicyLayer)
  (requested-level lint_core.LintLevel)
  (effective-level lint_core.LintLevel)
  (outcome LintPolicyTraceOutcome)
  (origin LintPolicyOrigin)
  (reason String))

(defstruct LintPolicyTrace
  (slots (__tl_dyn-array LintPolicyTraceEntry))
  (len i64))

(define (lint-policy-trace-with-capacity [capacity : i64]) : LintPolicyTrace
  (LintPolicyTrace
    (__tl_make-array
      LintPolicyTraceEntry
      (if (< capacity 1)
        1
        capacity))
    0))

(define (lint-policy-trace-count [items : (& items LintPolicyTrace)]) : i64
  items.len)

(define (lint-policy-trace-ref
  [items : (& items LintPolicyTrace)]
  [index : i64]) : LintPolicyTraceEntry
  (owned_view.compiler-owned-array-element-shared-view items.slots index))

(define (lint-policy-trace-add
  [items : LintPolicyTrace]
  [entry : LintPolicyTraceEntry]) : LintPolicyTrace
  (begin
    (set! (array-ref items.slots items.len) entry)
    (LintPolicyTrace items.slots (+ items.len 1))))

;: Deterministic work census used by bounded-overhead tests and measurements.
(defstruct LintPolicyStats
  (registry-rules i64)
  (group-definitions i64)
  (group-members i64)
  (assignments i64)
  (expanded-rule-updates i64)
  (trace-entries i64))

(defstruct LintPolicyResolution
  (decisions LintPolicyDecisions)
  (diagnostics LintPolicyDiagnostics)
  (trace LintPolicyTrace)
  (stats LintPolicyStats))

(define (lint-policy-resolution-diagnostics-count
  [resolution : (& resolution LintPolicyResolution)]) : i64
  (lint-policy-diagnostics-count resolution.diagnostics))

(define (lint-policy-resolution-trace-count
  [resolution : (& resolution LintPolicyResolution)]) : i64
  (lint-policy-trace-count resolution.trace))

(define (lint-policy-group-member-total [groups : (& groups LintPolicyGroups)]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index groups.len)
        (begin
          (set!
            count
            (+ count (lint-policy-groups-ref groups index).members.len))
          (set! index (+ index 1))))
      count)))

;: Build one deterministic open-addressed name index for this resolution.
;: The first declaration wins the index; duplicate validation reports later
;: declarations without changing lookup targets.
(define (lint-policy-group-index-build [groups : (& groups LintPolicyGroups)]) : lint_policy_string_i64_map.Map
  (let
    [index-map : lint_policy_string_i64_map.Map
      (lint_policy_string_i64_map.with-capacity (+ groups.len 1))]
    [index : i64 0]
    (begin
      (while (< index groups.len)
        (let
          [group : LintPolicyGroup (lint-policy-groups-ref groups index)]
          (begin
            (lint_policy_string_i64_map.insert-if-absent-ref!
              (&mut index-map)
              (string.copy group.name)
              index)
            (set! index (+ index 1)))))
      index-map)))

(define (lint-policy-group-indexed
  [index-map : (& index-map lint_policy_string_i64_map.Map)]
  [name : (& name str)]) : i64
  (lint_policy_string_i64_map.lookup-value-or
    (lint_policy_string_i64_map.get-borrowed index-map name)
    -1))

(define (lint-policy-rule-index-from
  [rules : (& rules lint_core.LintRuleList)]
  [name : (& name str)]
  [index : i64]) : i64
  (if (>= index (lint_core.lint-rule-list-count rules))
    -1
    (if (string.eq (lint_core.lint-rule-list-ref rules index).rule-id name)
      index
      (lint-policy-rule-index-from rules name (+ index 1)))))

(define (lint-policy-rule-index
  [rules : (& rules lint_core.LintRuleList)]
  [name : (& name str)]) : i64
  (lint-policy-rule-index-from rules name 0))

(define (lint-policy-diagnostic
  [kind : LintPolicyDiagnosticKind]
  [subject : String]
  [layer : LintPolicyLayer]
  [origin : LintPolicyOrigin]
  [message : String]) : LintPolicyDiagnostic
  (LintPolicyDiagnostic kind subject layer origin message))

(define (lint-policy-unknown-rule-diagnostic
  [name : String]
  [layer : LintPolicyLayer]
  [origin : LintPolicyOrigin]) : LintPolicyDiagnostic
  (lint-policy-diagnostic
    LintPolicyDiagnosticKind.UnknownRule
    (owned_view.compiler-owned-shared-view name)
    layer
    origin
    (str_cat.str-cat "unknown lint rule: " name)))

(define (lint-policy-unknown-group-diagnostic
  [name : String]
  [layer : LintPolicyLayer]
  [origin : LintPolicyOrigin]) : LintPolicyDiagnostic
  (lint-policy-diagnostic
    LintPolicyDiagnosticKind.UnknownGroup
    (owned_view.compiler-owned-shared-view name)
    layer
    origin
    (str_cat.str-cat "unknown lint group: " name)))

(defstruct LintPolicyGroupValidation
  (valid (__tl_dyn-array bool))
  (diagnostics LintPolicyDiagnostics)
  (member-count i64)
  (index-map lint_policy_string_i64_map.Map))

(define (lint-policy-validate-group-names
  [groups : (& groups LintPolicyGroups)]
  [index-map : (& index-map lint_policy_string_i64_map.Map)]
  [valid : (__tl_dyn-array bool)]
  [diagnostics : LintPolicyDiagnostics]) : LintPolicyDiagnostics
  (let
    [index : i64 0]
    [out : LintPolicyDiagnostics diagnostics]
    (begin
      (while (< index groups.len)
        (let
          [group : LintPolicyGroup (lint-policy-groups-ref groups index)]
          [first : i64 (lint-policy-group-indexed index-map group.name)]
          (begin
            (if (> (lint_core.lint-built-in-group-mask group.name) 0)
              (begin
                (set! (array-ref valid index) false)
                (set!
                  out
                  (lint-policy-diagnostics-add
                    out
                    (lint-policy-diagnostic
                      LintPolicyDiagnosticKind.DuplicateGroup
                      (owned_view.compiler-owned-shared-view group.name)
                      group.layer
                      (owned_view.compiler-owned-shared-view group.origin)
                      (str_cat.str-cat
                        "custom lint group redefines built-in group: "
                        (owned_view.compiler-owned-shared-view group.name))))))
              unit)
            (if (and (>= first 0) (not (= first index)))
              (begin
                (set! (array-ref valid first) false)
                (set! (array-ref valid index) false)
                (set!
                  out
                  (lint-policy-diagnostics-add
                    out
                    (lint-policy-diagnostic
                      LintPolicyDiagnosticKind.DuplicateGroup
                      (owned_view.compiler-owned-shared-view group.name)
                      group.layer
                      (owned_view.compiler-owned-shared-view group.origin)
                      (str_cat.str-cat
                        "duplicate lint group definition: "
                        (owned_view.compiler-owned-shared-view group.name))))))
              unit)
            (set! index (+ index 1)))))
      out)))

(define (lint-policy-validate-group-members
  [rules : (& rules lint_core.LintRuleList)]
  [groups : (& groups LintPolicyGroups)]
  [index-map : (& index-map lint_policy_string_i64_map.Map)]
  [valid : (__tl_dyn-array bool)]
  [diagnostics : LintPolicyDiagnostics]) : LintPolicyDiagnostics
  (let
    [group-index : i64 0]
    [out : LintPolicyDiagnostics diagnostics]
    (begin
      (while (< group-index groups.len)
        (let
          [group : LintPolicyGroup (lint-policy-groups-ref groups group-index)]
          [member-index : i64 0]
          (begin
            (while (< member-index group.members.len)
              (begin
                (match (lint-policy-group-members-ref
                  group.members
                  member-index)
                  [(LintPolicyGroupMember.Rule name)
                    (if (< (lint-policy-rule-index rules name) 0)
                      (begin
                        (set! (array-ref valid group-index) false)
                        (set!
                          out
                          (lint-policy-diagnostics-add
                            out
                            (lint-policy-unknown-rule-diagnostic
                              name
                              group.layer
                              group.origin))))
                      unit)]
                  [(LintPolicyGroupMember.Group name)
                    (if (and
                      (= (lint_core.lint-built-in-group-mask name) 0)
                      (< (lint-policy-group-indexed index-map name) 0))
                      (begin
                        (set! (array-ref valid group-index) false)
                        (set!
                          out
                          (lint-policy-diagnostics-add
                            out
                            (lint-policy-unknown-group-diagnostic
                              name
                              group.layer
                              group.origin))))
                      unit)])
                (set! member-index (+ member-index 1))))
            (set! group-index (+ group-index 1)))))
      out)))

;; A graph walk returns an owned diagnostic buffer plus an in-flight cycle
;; root while unwinding. The root clears propagation, so groups that merely
;; depend on a cycle receive InvalidGroupReference rather than GroupCycle.
(defstruct LintPolicyGroupGraphWalk
  (diagnostics LintPolicyDiagnostics)
  (cycle-root i64)
  (propagating-cycle bool))

(define (lint-policy-validate-group-graph-from
  [groups : (& groups LintPolicyGroups)]
  [index-map : (& index-map lint_policy_string_i64_map.Map)]
  [valid : (&mut valid (__tl_dyn-array bool))]
  [colors : (&mut colors (__tl_dyn-array i64))]
  [current : i64]
  [diagnostics : LintPolicyDiagnostics]) : LintPolicyGroupGraphWalk
  (if (= (array-ref colors current) 1)
    (LintPolicyGroupGraphWalk diagnostics current true)
    (if (= (array-ref colors current) 2)
      (LintPolicyGroupGraphWalk diagnostics -1 false)
      (let
        [group : LintPolicyGroup (lint-policy-groups-ref groups current)]
        [member-index : i64 0]
        [out : LintPolicyDiagnostics diagnostics]
        [cycle-root : i64 -1]
        [propagating : bool false]
        [cycle-here : bool false]
        [invalid-reference : bool false]
        [done : bool false]
        (begin
          (set! (array-ref colors current) 1)
          (while (and (not done) (< member-index group.members.len))
            (begin
              (match (lint-policy-group-members-ref group.members member-index)
                [(LintPolicyGroupMember.Rule _) unit]
                [(LintPolicyGroupMember.Group name)
                  (let
                    [child : i64 (lint-policy-group-indexed index-map name)]
                    (when
                      (>= child 0)
                      (if (not (array-ref valid child))
                        (set! invalid-reference true)
                        (if (= (array-ref colors child) 1)
                          (begin
                            (set! cycle-root child)
                            (set! propagating true))
                          (when
                            (= (array-ref colors child) 0)
                            (let
                              [child-walk : LintPolicyGroupGraphWalk
                                (lint-policy-validate-group-graph-from
                                  groups
                                  index-map
                                  valid
                                  colors
                                  child
                                  (owned_view.compiler-owned-shared-view out))]
                              (begin
                                (set! out child-walk.diagnostics)
                                (if child-walk.propagating-cycle
                                  (begin
                                    (set! cycle-root child-walk.cycle-root)
                                    (set! propagating true))
                                  (when
                                    (not (array-ref valid child))
                                    (set! invalid-reference true))))))))
                      (when
                        propagating
                        (begin
                          (when
                            (array-ref valid current)
                            (begin
                              (set! (array-ref valid current) false)
                              (set!
                                out
                                (lint-policy-diagnostics-add
                                  out
                                  (lint-policy-diagnostic
                                    LintPolicyDiagnosticKind.GroupCycle
                                    (owned_view.compiler-owned-shared-view
                                      group.name)
                                    group.layer
                                    (owned_view.compiler-owned-shared-view
                                      group.origin)
                                    (str_cat.str-cat
                                      "cyclic lint group definition: "
                                      (owned_view.compiler-owned-shared-view
                                        group.name)))))))
                          (set! cycle-here true)
                          (set! done true)
                          (when (= current cycle-root) (set! propagating false))))))])
              (set! member-index (+ member-index 1))))
          (when
            (and invalid-reference (not cycle-here) (array-ref valid current))
            (begin
              (set! (array-ref valid current) false)
              (set!
                out
                (lint-policy-diagnostics-add
                  out
                  (lint-policy-diagnostic
                    LintPolicyDiagnosticKind.InvalidGroupReference
                    (owned_view.compiler-owned-shared-view group.name)
                    group.layer
                    (owned_view.compiler-owned-shared-view group.origin)
                    (str_cat.str-cat
                      "lint group depends on an invalid group: "
                      (owned_view.compiler-owned-shared-view group.name)))))))
          (set! (array-ref colors current) 2)
          (LintPolicyGroupGraphWalk out cycle-root propagating))))))

(define (lint-policy-validate-group-graph
  [groups : (& groups LintPolicyGroups)]
  [index-map : (& index-map lint_policy_string_i64_map.Map)]
  [valid : (&mut valid (__tl_dyn-array bool))]
  [diagnostics : LintPolicyDiagnostics]) : LintPolicyDiagnostics
  (let
    [colors : (__tl_dyn-array i64) (__tl_make-array i64 groups.len)]
    [index : i64 0]
    [out : LintPolicyDiagnostics diagnostics]
    (begin
      (while (< index groups.len)
        (begin
          (when
            (and (array-ref valid index) (= (array-ref colors index) 0))
            (let
              [walk : LintPolicyGroupGraphWalk
                (lint-policy-validate-group-graph-from
                  groups
                  index-map
                  valid
                  (&mut colors)
                  index
                  (owned_view.compiler-owned-shared-view out))]
              (set! out walk.diagnostics)))
          (set! index (+ index 1))))
      out)))

(define (lint-policy-validate-groups
  [rules : (& rules lint_core.LintRuleList)]
  [groups : (& groups LintPolicyGroups)]
  [capacity : i64]) : LintPolicyGroupValidation
  (let
    [valid : (__tl_dyn-array bool) (__tl_make-array bool groups.len)]
    [index-map : lint_policy_string_i64_map.Map
      (lint-policy-group-index-build groups)]
    [index : i64 0]
    [diagnostics : LintPolicyDiagnostics
      (lint-policy-diagnostics-with-capacity capacity)]
    (begin
      (while (< index groups.len)
        (begin
          (set! (array-ref valid index) true)
          (set! index (+ index 1))))
      (set!
        diagnostics
        (lint-policy-validate-group-names
          groups
          index-map
          (owned_view.compiler-owned-shared-view valid)
          diagnostics))
      (set!
        diagnostics
        (lint-policy-validate-group-members
          rules
          groups
          index-map
          (owned_view.compiler-owned-shared-view valid)
          diagnostics))
      (set!
        diagnostics
        (lint-policy-validate-group-graph
          groups
          index-map
          (&mut valid)
          diagnostics))
      (LintPolicyGroupValidation
        valid
        diagnostics
        (lint-policy-group-member-total groups)
        index-map))))

(define (lint-policy-group-contains-rule?
  [rules : (& rules lint_core.LintRuleList)]
  [groups : (& groups LintPolicyGroups)]
  [index-map : (& index-map lint_policy_string_i64_map.Map)]
  [valid : (& valid (__tl_dyn-array bool))]
  [membership : (&mut membership (__tl_dyn-array bool))]
  [states : (&mut states (__tl_dyn-array i64))]
  [group-index : i64]
  [rule-index : i64]) : bool
  (let
    [rule-count : i64 (lint_core.lint-rule-list-count rules)]
    [slot : i64 (+ (* group-index rule-count) rule-index)]
    [state : i64 (array-ref states slot)]
    (cond
      [(= state 2) (array-ref membership slot)]
      [(= state 1) false]
      [(not (array-ref valid group-index))
        (begin
          (set! (array-ref membership slot) false)
          (set! (array-ref states slot) 2)
          false)]
      [else
        (let
          [group : LintPolicyGroup (lint-policy-groups-ref groups group-index)]
          [rule : lint_core.LintRule
            (lint_core.lint-rule-list-ref rules rule-index)]
          (begin
            (set! (array-ref states slot) 1)
            (let
              [found : bool
                (lint-policy-group-members-contain-rule?
                  rules
                  groups
                  index-map
                  valid
                  membership
                  states
                  group.members
                  rule
                  rule-index
                  0)]
              (begin
                (set! (array-ref membership slot) found)
                (set! (array-ref states slot) 2)
                found))))])))

(define (lint-policy-group-members-contain-rule?
  [rules : (& rules lint_core.LintRuleList)]
  [groups : (& groups LintPolicyGroups)]
  [index-map : (& index-map lint_policy_string_i64_map.Map)]
  [valid : (& valid (__tl_dyn-array bool))]
  [membership : (&mut membership (__tl_dyn-array bool))]
  [states : (&mut states (__tl_dyn-array i64))]
  [members : (& members LintPolicyGroupMembers)]
  [rule : (& rule lint_core.LintRule)]
  [rule-index : i64]
  [index : i64]) : bool
  (if (>= index members.len)
    false
    (match (lint-policy-group-members-ref members index)
      [(LintPolicyGroupMember.Rule name)
        (if (string.eq name rule.rule-id)
          true
          (lint-policy-group-members-contain-rule?
            rules
            groups
            index-map
            valid
            membership
            states
            members
            rule
            rule-index
            (+ index 1)))]
      [(LintPolicyGroupMember.Group name)
        (let
          [mask : i64 (lint_core.lint-built-in-group-mask name)]
          [child : i64 (lint-policy-group-indexed index-map name)]
          (if (if (> mask 0)
            (lint_core.lint-rule-in-built-in-group? rule name)
            (and
              (>= child 0)
              (lint-policy-group-contains-rule?
                rules
                groups
                index-map
                valid
                membership
                states
                child
                rule-index)))
            true
            (lint-policy-group-members-contain-rule?
              rules
              groups
              index-map
              valid
              membership
              states
              members
              rule
              rule-index
              (+ index 1))))])))

(define (lint-policy-build-group-membership
  [rules : (& rules lint_core.LintRuleList)]
  [groups : (& groups LintPolicyGroups)]
  [index-map : (& index-map lint_policy_string_i64_map.Map)]
  [valid : (& valid (__tl_dyn-array bool))]) : (__tl_dyn-array bool)
  (let
    [rule-count : i64 (lint_core.lint-rule-list-count rules)]
    [membership : (__tl_dyn-array bool)
      (__tl_make-array bool (* groups.len rule-count))]
    [states : (__tl_dyn-array i64)
      (__tl_make-array i64 (* groups.len rule-count))]
    [group-index : i64 0]
    (begin
      (while (< group-index groups.len)
        (let
          [rule-index : i64 0]
          (begin
            (while (< rule-index rule-count)
              (begin
                (lint-policy-group-contains-rule?
                  rules
                  groups
                  index-map
                  valid
                  (&mut membership)
                  (&mut states)
                  group-index
                  rule-index)
                (set! rule-index (+ rule-index 1))))
            (set! group-index (+ group-index 1)))))
      membership)))

(define (lint-policy-default-decisions
  [rules : (& rules lint_core.LintRuleList)]) : LintPolicyDecisions
  (let
    [count : i64 (lint_core.lint-rule-list-count rules)]
    [slots : (__tl_dyn-array LintPolicyDecision)
      (__tl_make-array LintPolicyDecision count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [rule : lint_core.LintRule (lint_core.lint-rule-list-ref rules index)]
          (begin
            (set!
              (array-ref slots index)
              (LintPolicyDecision
                rule.rule-id
                rule.default-level
                LintPolicyLayer.Builtin
                -1
                (lint-policy-built-in-origin)))
            (set! index (+ index 1)))))
      (LintPolicyDecisions slots count))))

(define (lint-policy-decision-find-from
  [decisions : (& decisions LintPolicyDecisions)]
  [rule-id : (& rule-id str)]
  [index : i64]) : LintMaybePolicyDecision
  (if (>= index decisions.len)
    LintMaybePolicyDecision.NotFound
    (let
      [decision : LintPolicyDecision
        (lint-policy-decisions-ref decisions index)]
      (if (string.eq decision.rule-id rule-id)
        (LintMaybePolicyDecision.Found decision)
        (lint-policy-decision-find-from decisions rule-id (+ index 1))))))

(define (lint-policy-decision-find
  [resolution : (& resolution LintPolicyResolution)]
  [rule-id : (& rule-id str)]) : LintMaybePolicyDecision
  (lint-policy-decision-find-from resolution.decisions rule-id 0))

(define (lint-policy-assignment-key
  [assignment : (& assignment LintPolicyAssignment)]
  [subject-name : (& subject-name str)]) : String
  (str_cat.str-cat
    (string.int->string (lint-policy-layer-rank assignment.layer))
    ":"
    (if (lint-policy-subject-is-rule? assignment.subject)
      "rule:"
      "group:")
    (string.copy subject-name)))

(define (lint-policy-assignment-signature
  [assignment : (& assignment LintPolicyAssignment)]) : i64
  (+
    (* (lint_core.lint-level-rank assignment.level) 2)
    (match assignment.mode
      [(LintPolicyAssignmentMode.Exact) 0]
      [(LintPolicyAssignmentMode.Minimum) 1])))

(define (lint-policy-validate-assignments
  [rules : (& rules lint_core.LintRuleList)]
  [groups : (& groups LintPolicyGroups)]
  [index-map : (& index-map lint_policy_string_i64_map.Map)]
  [valid-groups : (& valid-groups (__tl_dyn-array bool))]
  [assignments : (& assignments LintPolicyAssignments)]
  [diagnostics : LintPolicyDiagnostics]) : LintPolicyDiagnostics
  (let
    [index : i64 0]
    [out : LintPolicyDiagnostics diagnostics]
    [seen : lint_policy_string_i64_map.Map
      (lint_policy_string_i64_map.with-capacity (+ assignments.len 1))]
    (begin
      (while (< index assignments.len)
        (let
          [assignment : LintPolicyAssignment
            (lint-policy-assignments-ref assignments index)]
          [subject-name : String (lint-policy-subject-name assignment.subject)]
          [assignment-key : String
            (lint-policy-assignment-key assignment subject-name)]
          [signature : i64 (lint-policy-assignment-signature assignment)]
          [prior-signature : i64
            (lint_policy_string_i64_map.lookup-value-or
              (lint_policy_string_i64_map.get-borrowed
                (& seen)
                (& assignment-key))
              -1)]
          (begin
            (match assignment.subject
              [(LintPolicySubject.Rule name)
                (if (< (lint-policy-rule-index rules name) 0)
                  (set!
                    out
                    (lint-policy-diagnostics-add
                      out
                      (lint-policy-unknown-rule-diagnostic
                        name
                        assignment.layer
                        (owned_view.compiler-owned-shared-view
                          assignment.origin))))
                  unit)]
              [(LintPolicySubject.Group name)
                (let
                  [custom : i64 (lint-policy-group-indexed index-map name)]
                  (if (and
                    (= (lint_core.lint-built-in-group-mask name) 0)
                    (< custom 0))
                    (set!
                      out
                      (lint-policy-diagnostics-add
                        out
                        (lint-policy-unknown-group-diagnostic
                          name
                          assignment.layer
                          (owned_view.compiler-owned-shared-view
                            assignment.origin))))
                    (if (and
                      (>= custom 0)
                      (not (array-ref valid-groups custom)))
                      (set!
                        out
                        (lint-policy-diagnostics-add
                          out
                          (lint-policy-diagnostic
                            LintPolicyDiagnosticKind.InvalidGroupReference
                            (owned_view.compiler-owned-shared-view name)
                            assignment.layer
                            (owned_view.compiler-owned-shared-view
                              assignment.origin)
                            (str_cat.str-cat
                              "lint assignment references invalid group: "
                              name))))
                      unit)))])
            (when
              assignment.selected
              (if (>= prior-signature 0)
                (when
                  (not (= prior-signature signature))
                  (set!
                    out
                    (lint-policy-diagnostics-add
                      out
                      (lint-policy-diagnostic
                        LintPolicyDiagnosticKind.ContradictoryAssignment
                        (owned_view.compiler-owned-shared-view subject-name)
                        assignment.layer
                        assignment.origin
                        (str_cat.str-cat
                          "contradictory lint assignments in "
                          (lint-policy-layer-name assignment.layer)
                          " layer for "
                          subject-name)))))
                (lint_policy_string_i64_map.insert-ref!
                  (&mut seen)
                  assignment-key
                  signature)))
            (set! index (+ index 1)))))
      out)))

(defstruct LintPolicyApplyState
  (diagnostics LintPolicyDiagnostics)
  (trace LintPolicyTrace)
  (expanded-rule-updates i64))

(define (lint-policy-trace-entry
  [assignment-index : i64]
  [rule-id : String]
  [effective-level : lint_core.LintLevel]
  [assignment : LintPolicyAssignment]
  [outcome : LintPolicyTraceOutcome]
  [reason : String]) : LintPolicyTraceEntry
  (LintPolicyTraceEntry
    assignment-index
    rule-id
    assignment.layer
    assignment.level
    effective-level
    outcome
    assignment.origin
    reason))

(define (lint-policy-apply-to-rule
  [decisions : LintPolicyDecisions]
  [rule-index : i64]
  [assignment : LintPolicyAssignment]
  [assignment-index : i64]
  [state : LintPolicyApplyState]) : LintPolicyApplyState
  (let
    [current : LintPolicyDecision
      (lint-policy-decisions-ref decisions rule-index)]
    [current-rank : i64 (lint_core.lint-level-rank current.level)]
    [requested-rank : i64 (lint_core.lint-level-rank assignment.level)]
    [is-minimum : bool
      (match assignment.mode
        [(LintPolicyAssignmentMode.Minimum) true]
        [_ false])]
    [forbid-lowering : bool
      (and (= current-rank 3) (not is-minimum) (< requested-rank current-rank))]
    (if forbid-lowering
      (LintPolicyApplyState
        (lint-policy-diagnostics-add
          state.diagnostics
          (lint-policy-diagnostic
            LintPolicyDiagnosticKind.ForbidLowering
            (owned_view.compiler-owned-shared-view current.rule-id)
            assignment.layer
            (owned_view.compiler-owned-shared-view assignment.origin)
            (str_cat.str-cat
              "lint level forbid cannot be lowered for rule: "
              (owned_view.compiler-owned-shared-view current.rule-id))))
        (lint-policy-trace-add
          state.trace
          (lint-policy-trace-entry
            assignment-index
            (owned_view.compiler-owned-shared-view current.rule-id)
            current.level
            assignment
            LintPolicyTraceOutcome.Rejected
            "forbid cannot be lowered"))
        (+ state.expanded-rule-updates 1))
      (if (and is-minimum (>= current-rank requested-rank))
        (LintPolicyApplyState
          state.diagnostics
          (lint-policy-trace-add
            state.trace
            (lint-policy-trace-entry
              assignment-index
              current.rule-id
              current.level
              assignment
              LintPolicyTraceOutcome.Shadowed
              "minimum already satisfied"))
          (+ state.expanded-rule-updates 1))
        (begin
          (set!
            (array-ref decisions.slots rule-index)
            (LintPolicyDecision
              (owned_view.compiler-owned-shared-view current.rule-id)
              assignment.level
              assignment.layer
              assignment-index
              (owned_view.compiler-owned-shared-view assignment.origin)))
          (LintPolicyApplyState
            state.diagnostics
            (lint-policy-trace-add
              state.trace
              (lint-policy-trace-entry
                assignment-index
                current.rule-id
                assignment.level
                assignment
                LintPolicyTraceOutcome.Applied
                (if is-minimum
                  "minimum raised effective level"
                  "exact assignment")))
            (+ state.expanded-rule-updates 1)))))))

(define (lint-policy-group-assignment-valid?
  [groups : (& groups LintPolicyGroups)]
  [index-map : (& index-map lint_policy_string_i64_map.Map)]
  [valid-groups : (& valid-groups (__tl_dyn-array bool))]
  [name : (& name str)]) : bool
  (if (> (lint_core.lint-built-in-group-mask name) 0)
    true
    (let
      [custom : i64 (lint-policy-group-indexed index-map name)]
      (and (>= custom 0) (array-ref valid-groups custom)))))

(define (lint-policy-group-assignment-matches-rule?
  [rules : (& rules lint_core.LintRuleList)]
  [groups : (& groups LintPolicyGroups)]
  [index-map : (& index-map lint_policy_string_i64_map.Map)]
  [valid-groups : (& valid-groups (__tl_dyn-array bool))]
  [membership : (& membership (__tl_dyn-array bool))]
  [name : (& name str)]
  [rule-index : i64]) : bool
  (let
    [mask : i64 (lint_core.lint-built-in-group-mask name)]
    [custom : i64 (lint-policy-group-indexed index-map name)]
    [rule : lint_core.LintRule (lint_core.lint-rule-list-ref rules rule-index)]
    (if (> mask 0)
      (lint_core.lint-rule-in-built-in-group? rule name)
      (and
        (>= custom 0)
        (array-ref valid-groups custom)
        (array-ref
          membership
          (+ (* custom (lint_core.lint-rule-list-count rules)) rule-index))))))

(define (lint-policy-apply-group-assignment
  [rules : (& rules lint_core.LintRuleList)]
  [groups : (& groups LintPolicyGroups)]
  [index-map : (& index-map lint_policy_string_i64_map.Map)]
  [valid-groups : (& valid-groups (__tl_dyn-array bool))]
  [membership : (& membership (__tl_dyn-array bool))]
  [decisions : LintPolicyDecisions]
  [assignment : LintPolicyAssignment]
  [assignment-index : i64]
  [state : LintPolicyApplyState]) : LintPolicyApplyState
  (match assignment.subject
    [(LintPolicySubject.Rule _) state]
    [(LintPolicySubject.Group name)
      (if (not
        (lint-policy-group-assignment-valid? groups index-map valid-groups name))
        (LintPolicyApplyState
          state.diagnostics
          (lint-policy-trace-add
            state.trace
            (lint-policy-trace-entry
              assignment-index
              ""
              (lint_core.LintLevel.Allow)
              assignment
              LintPolicyTraceOutcome.Rejected
              "unknown or invalid group"))
          state.expanded-rule-updates)
        (let
          [rule-index : i64 0]
          [matched : bool false]
          [out : LintPolicyApplyState state]
          (begin
            (while (< rule-index (lint_core.lint-rule-list-count rules))
              (begin
                (if (lint-policy-group-assignment-matches-rule?
                  rules
                  groups
                  index-map
                  valid-groups
                  membership
                  name
                  rule-index)
                  (begin
                    (set! matched true)
                    (set!
                      out
                      (lint-policy-apply-to-rule
                        (owned_view.compiler-owned-shared-view decisions)
                        rule-index
                        (owned_view.compiler-owned-shared-view assignment)
                        assignment-index
                        out)))
                  unit)
                (set! rule-index (+ rule-index 1))))
            (if matched
              out
              (LintPolicyApplyState
                out.diagnostics
                (lint-policy-trace-add
                  out.trace
                  (lint-policy-trace-entry
                    assignment-index
                    ""
                    assignment.level
                    assignment
                    LintPolicyTraceOutcome.Shadowed
                    "group expands to no rules"))
                out.expanded-rule-updates)))))]))

(define (lint-policy-apply-rule-assignment
  [rules : (& rules lint_core.LintRuleList)]
  [decisions : LintPolicyDecisions]
  [assignment : LintPolicyAssignment]
  [assignment-index : i64]
  [state : LintPolicyApplyState]) : LintPolicyApplyState
  (match assignment.subject
    [(LintPolicySubject.Group _) state]
    [(LintPolicySubject.Rule name)
      (let
        [rule-index : i64 (lint-policy-rule-index rules name)]
        (if (< rule-index 0)
          (LintPolicyApplyState
            state.diagnostics
            (lint-policy-trace-add
              state.trace
              (lint-policy-trace-entry
                assignment-index
                name
                (lint_core.LintLevel.Allow)
                assignment
                LintPolicyTraceOutcome.Rejected
                "unknown rule"))
            state.expanded-rule-updates)
          (lint-policy-apply-to-rule
            decisions
            rule-index
            assignment
            assignment-index
            state)))]))

(define (lint-policy-apply-layer-kind
  [rules : (& rules lint_core.LintRuleList)]
  [groups : (& groups LintPolicyGroups)]
  [index-map : (& index-map lint_policy_string_i64_map.Map)]
  [valid-groups : (& valid-groups (__tl_dyn-array bool))]
  [membership : (& membership (__tl_dyn-array bool))]
  [assignments : (& assignments LintPolicyAssignments)]
  [decisions : LintPolicyDecisions]
  [layer-rank : i64]
  [rules-only : bool]
  [state : LintPolicyApplyState]) : LintPolicyApplyState
  (let
    [index : i64 0]
    [out : LintPolicyApplyState state]
    (begin
      (while (< index assignments.len)
        (let
          [assignment : LintPolicyAssignment
            (lint-policy-assignments-ref assignments index)]
          (begin
            (if (and
              assignment.selected
              (= (lint-policy-layer-rank assignment.layer) layer-rank)
              (if rules-only
                (lint-policy-subject-is-rule? assignment.subject)
                (not (lint-policy-subject-is-rule? assignment.subject))))
              (set!
                out
                (if rules-only
                  (lint-policy-apply-rule-assignment
                    rules
                    (owned_view.compiler-owned-shared-view decisions)
                    assignment
                    index
                    out)
                  (lint-policy-apply-group-assignment
                    rules
                    groups
                    index-map
                    valid-groups
                    membership
                    (owned_view.compiler-owned-shared-view decisions)
                    assignment
                    index
                    out)))
              unit)
            (set! index (+ index 1)))))
      out)))

(define (lint-policy-record-inactive-assignments
  [assignments : (& assignments LintPolicyAssignments)]
  [trace : LintPolicyTrace]) : LintPolicyTrace
  (let
    [index : i64 0]
    [out : LintPolicyTrace trace]
    (begin
      (while (< index assignments.len)
        (let
          [assignment : LintPolicyAssignment
            (lint-policy-assignments-ref assignments index)]
          (begin
            (unless
              assignment.selected
              (set!
                out
                (lint-policy-trace-add
                  out
                  (lint-policy-trace-entry
                    index
                    ""
                    (lint_core.LintLevel.Allow)
                    assignment
                    LintPolicyTraceOutcome.Inactive
                    "cfg input not selected"))))
            (set! index (+ index 1)))))
      out)))

(define (lint-policy-resolve
  [groups : LintPolicyGroups]
  [assignments : LintPolicyAssignments]) : LintPolicyResolution
  (let
    [rules : lint_core.LintRuleList (lint_core.lint-rule-registry)]
    [rule-count : i64 (lint_core.lint-rule-list-count rules)]
    [member-count : i64 (lint-policy-group-member-total groups)]
    [diagnostic-capacity : i64
      (+ 8 member-count (* groups.len 3) (* assignments.len (+ rule-count 2)))]
    [validation : LintPolicyGroupValidation
      (lint-policy-validate-groups rules groups diagnostic-capacity)]
    [valid-groups : (__tl_dyn-array bool)
      (owned_view.compiler-owned-shared-view validation.valid)]
    [group-index-map : lint_policy_string_i64_map.Map
      (owned_view.compiler-owned-shared-view validation.index-map)]
    [diagnostics : LintPolicyDiagnostics
      (lint-policy-validate-assignments
        rules
        groups
        group-index-map
        valid-groups
        assignments
        validation.diagnostics)]
    [membership : (__tl_dyn-array bool)
      (lint-policy-build-group-membership
        rules
        groups
        group-index-map
        valid-groups)]
    [decisions : LintPolicyDecisions (lint-policy-default-decisions rules)]
    [trace : LintPolicyTrace
      (lint-policy-record-inactive-assignments
        assignments
        (lint-policy-trace-with-capacity
          (+ 1 (* assignments.len (+ rule-count 1)))))]
    [state : LintPolicyApplyState (LintPolicyApplyState diagnostics trace 0)]
    [layer : i64 0]
    (begin
      (while (< layer 6)
        (begin
          (set!
            state
            (lint-policy-apply-layer-kind
              rules
              groups
              group-index-map
              valid-groups
              membership
              assignments
              (owned_view.compiler-owned-shared-view decisions)
              layer
              false
              state))
          (set!
            state
            (lint-policy-apply-layer-kind
              rules
              groups
              group-index-map
              valid-groups
              membership
              assignments
              (owned_view.compiler-owned-shared-view decisions)
              layer
              true
              state))
          (set! layer (+ layer 1))))
      (let
        [trace-count : i64 (lint-policy-trace-count state.trace)]
        (LintPolicyResolution
          decisions
          state.diagnostics
          state.trace
          (LintPolicyStats
            rule-count
            groups.len
            validation.member-count
            assignments.len
            state.expanded-rule-updates
            trace-count))))))

(define (lint-policy-default) : LintPolicyResolution
  (lint-policy-resolve
    (lint-policy-groups-empty)
    (lint-policy-assignments-empty)))

(define (lint-policy-rule-assignment
  [name : String]
  [level : lint_core.LintLevel]
  [layer : LintPolicyLayer]
  [mode : LintPolicyAssignmentMode]
  [selected : bool]
  [origin : LintPolicyOrigin]) : LintPolicyAssignment
  (LintPolicyAssignment
    (LintPolicySubject.Rule name)
    level
    layer
    mode
    selected
    origin))

(define (lint-policy-group-assignment
  [name : String]
  [level : lint_core.LintLevel]
  [layer : LintPolicyLayer]
  [mode : LintPolicyAssignmentMode]
  [selected : bool]
  [origin : LintPolicyOrigin]) : LintPolicyAssignment
  (LintPolicyAssignment
    (LintPolicySubject.Group name)
    level
    layer
    mode
    selected
    origin))

(defstruct LintPolicyResolvedFinding
  (finding lint_core.LintFinding)
  (decision LintPolicyDecision))

;: Attach the effective level and exact winning origin to a policy-neutral
;: finding. Unknown collector rule ids fail closed to `allow`; registry-aware
;: composition services should diagnose such collector bugs separately.
(define (lint-policy-resolve-finding
  [resolution : LintPolicyResolution]
  [finding : lint_core.LintFinding]) : LintPolicyResolvedFinding
  (let
    [rule-id : String (owned_view.compiler-owned-shared-view finding.rule-id)]
    (match (lint-policy-decision-find resolution rule-id)
      [(LintMaybePolicyDecision.Found decision)
        (LintPolicyResolvedFinding finding decision)]
      [(LintMaybePolicyDecision.NotFound)
        (LintPolicyResolvedFinding
          finding
          (LintPolicyDecision
            rule-id
            (lint_core.LintLevel.Allow)
            LintPolicyLayer.Builtin
            -1
            (lint-policy-origin
              "registry"
              "unknown collector rule fails closed")))])))

(define (lint-policy-level-enabled? [level : lint_core.LintLevel]) : bool
  (> (lint_core.lint-level-rank level) 0))

(define (lint-policy-rule-enabled?
  [resolution : (& resolution LintPolicyResolution)]
  [rule-id : (& rule-id str)]) : bool
  (match (lint-policy-decision-find resolution rule-id)
    [(LintMaybePolicyDecision.NotFound) false]
    [(LintMaybePolicyDecision.Found decision)
      (lint-policy-level-enabled? decision.level)]))

(define (lint-policy-resolved-finding-enabled?
  [finding : LintPolicyResolvedFinding]) : bool
  (lint-policy-level-enabled? finding.decision.level))

(define (lint-policy-legacy-assignment-add
  [slots : (__tl_dyn-array LintPolicyAssignment)]
  [len : i64]
  [name : String]
  [reason : String]) : i64
  (begin
    (set!
      (array-ref slots len)
      (lint-policy-rule-assignment
        name
        (lint_core.LintLevel.Warn)
        LintPolicyLayer.Cli
        LintPolicyAssignmentMode.Minimum
        true
        (lint-policy-origin "legacy-cli" reason)))
    (+ len 1)))

;: Compatibility policy for the existing staged lint flags. Enabled flags are
;: monotonic at-least-warn floors, so they never lower project deny/forbid.
;: `--name-case` expands to its four current rules. The deprecated dotted-field
;: flag remains a no-op, and `--check` remains separate enforcement state.
(define (lint-policy-legacy-resolution
  [deprecated-string-concat : bool]
  [redundant-function-name : bool]
  [_prefer-dotted-field : bool]
  [name-case : bool]) : LintPolicyResolution
  (let
    [slots : (__tl_dyn-array LintPolicyAssignment)
      (__tl_make-array LintPolicyAssignment 6)]
    [len : i64 0]
    (begin
      (if deprecated-string-concat
        (set!
          len
          (lint-policy-legacy-assignment-add
            (owned_view.compiler-owned-shared-view slots)
            len
            (lint_core.lint-rule-deprecated-string-concat-id)
            "--deprecated-string-concat at-least-warn"))
        unit)
      (if redundant-function-name
        (set!
          len
          (lint-policy-legacy-assignment-add
            (owned_view.compiler-owned-shared-view slots)
            len
            (lint_core.lint-rule-redundant-function-name-id)
            "--redundant-function-name at-least-warn"))
        unit)
      (if name-case
        (begin
          (set!
            len
            (lint-policy-legacy-assignment-add
              (owned_view.compiler-owned-shared-view slots)
              len
              (lint_core.lint-rule-global-name-case-id)
              "--name-case expands global-name-case at-least-warn"))
          (set!
            len
            (lint-policy-legacy-assignment-add
              (owned_view.compiler-owned-shared-view slots)
              len
              (lint_core.lint-rule-function-name-case-id)
              "--name-case expands function-name-case at-least-warn"))
          (set!
            len
            (lint-policy-legacy-assignment-add
              (owned_view.compiler-owned-shared-view slots)
              len
              (lint_core.lint-rule-local-name-case-id)
              "--name-case expands local-name-case at-least-warn"))
          (set!
            len
            (lint-policy-legacy-assignment-add
              (owned_view.compiler-owned-shared-view slots)
              len
              (lint_core.lint-rule-type-name-case-id)
              "--name-case expands type-name-case at-least-warn")))
        unit)
      (lint-policy-resolve
        (lint-policy-groups-empty)
        (LintPolicyAssignments slots len)))))