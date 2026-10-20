;; Read-only facts for the opt-in compiler-dependency-audit build.
;; No retained compiler state: each event is serialized while its source owner
;; is alive. The audit runner owns the output and the lifetime of each child.
;; Consumer and retirement condition: docs/compiler-core-ir-dependencies.md.
(import stdlib.io)
(import stdlib.json)

(define (compiler-dependency-trace [kind : String] [value : String]) : unit
  (io.println
    "{}"
    (json.stringify
      (json.JsonArray
        (box
          (json.list-cons
            (json.JsonString kind)
            (json.list-cons (json.JsonString value) (json.list-empty))))))))