;; Required core IR boundary check. Inspect runs the canonical compiler in a
;; fresh process; this coordinator owns only stable JSON facts and policy data.
(import stdlib.io)
(import compiler_target_cfg_core as target_cfg)
(import compiler_cfg_core as cfg_core)
(import compiler_intern as ci)
(import sym_i64_env)
(import stdlib.byte_buf)
(import stdlib.string)
(import stdlib.fs)
(import stdlib.json)
(import stdlib.process)
(import stdlib.thread)
(import stdlib.env)
(import stdlib.str_cat)
(import stdlib.vector)
(import (vector.vector String core) as strings)

(defenum MaybeWorker
  (NoWorker)
  (HasWorker thread.ThreadString))

;; Read-only inputs published on the main thread before spawning a worker batch,
;; never mutated while workers run. Workers only read and copy into their own
;; atomic arenas, while scalar (mask, target) pairs are captured by value.
(define batch-inspector : String
  "")
(define batch-root : String
  "")
(define batch-cfg-names : strings.Vec
  (strings.new))

(defstruct ConfigSpace
  (names strings.Vec)
  (target-names strings.Vec))

;; Derive target-owned predicates from the existing target cfg builder. Keep
;; their values coherent with each target. Explicit cross-target user overrides
;; are outside the first boundary's scope (docs/compiler-core-ir-dependencies.md).
(define (target-name? [name : String]) : bool
  (let
    [linux : sym_i64_env.SymI64Env
      (target_cfg.compiler-target-cfgs
        target_cfg.CompilerTargetCfg.Linux
        (cfg_core.compiler-cfg-empty))]
    [windows : sym_i64_env.SymI64Env
      (target_cfg.compiler-target-cfgs
        target_cfg.CompilerTargetCfg.Windows
        (cfg_core.compiler-cfg-empty))]
    [id : i64 (ci.intern name)]
    (or
      (cfg_core.compiler-cfg-enabled? linux id)
      (cfg_core.compiler-cfg-enabled? windows id))))

(define (observe-cfg! [space : (&mut space ConfigSpace)] [name : String]) : unit
  (if (or
    (>= (index-of (& space.names) (& name)) 0)
    (>= (index-of (& space.target-names) (& name)) 0))
    unit
    (if (target-name? (string.copy (& name)))
      (strings.push-ref! (&mut space.target-names) name)
      (strings.push-ref! (&mut space.names) name))))

(defstruct Policy
  (paths strings.Vec)
  (roles strings.Vec)
  (seen (__tl_dyn-array bool)))

(define (fail [message : String]) : never
  (io.print-error message)
  (io.print-error "\n")
  (io.platform-exit 1))

(define (require [condition : bool] [message : String]) : unit
  (if condition
    unit
    (fail message)))

(define (index-of [values : (& values strings.Vec)] [value : (& value str)]) : i64
  (let
    [index : i64 0]
    (while (< index (strings.len values))
      (if (string.eq (strings.get values index "") value)
        (return index)
        (set! index (+ index 1))))
    -1))

(define (json-array [value : json.Json]) : json.JsonSeq
  (match value
    [(json.JsonArray boxed) (deref boxed)]
    [_ (fail "dependency boundary: expected a JSON array")]))

(define (json-string [value : json.Json]) : String
  (match value
    [(json.JsonString text) text]
    [_ (fail "dependency boundary: expected a JSON string")]))

(define (parse-json [text : (& text str)]) : json.Json
  (match (json.parse text)
    [(json.OkJson value) value]
    [(json.ErrJson message) (fail message)]))

(define (read-text [path : (& path str)]) : String
  (match (io.try-read-file path)
    [(io.OkIoBytes bytes)
      ;; The public binary-to-text conversion owns its result.
      (byte_buf.to-string bytes)]
    [(io.ErrIoBytes error) (fail (io.error-message error))]))

(define (read-policy [path : String] [root : (& root str)]) : Policy
  (let
    [text : String (read-text (& path))]
    [rows : json.JsonSeq (json-array (parse-json (& text)))]
    [paths : strings.Vec (strings.new)]
    [roles : strings.Vec (strings.new)]
    [seen : (__tl_dyn-array bool) (__tl_make-array bool rows.len)]
    [index : i64 0]
    [core-count : i64 0]
    (while (< index rows.len)
      (let
        [row : json.JsonSeq
          (json-array (json.clone-json (& (array-ref rows.slots index))))]
        [_shape : unit
          (require
            (= row.len 3)
            "dependency boundary: policy row requires path, role and reason")]
        [source : String
          (json-string (json.clone-json (& (array-ref row.slots 0))))]
        [role : String
          (json-string (json.clone-json (& (array-ref row.slots 1))))]
        [reason : String
          (json-string (json.clone-json (& (array-ref row.slots 2))))]
        [normalized : String (fs.path-normalize (& source))]
        (require
          (and
            (fs.path-safe-relative? (& source))
            (string.eq (& source) (& normalized)))
          "dependency boundary: policy path must be normalized and repository-relative")
        (require
          (> (string.string-length (& reason)) 0)
          "dependency boundary: policy reason is empty")
        (require
          (< (index-of (& paths) (& source)) 0)
          "dependency boundary: duplicate policy path")
        (require
          (or
            (string.eq (& role) "core")
            (string.eq (& role) "support")
            (string.eq (& role) "forbidden"))
          "dependency boundary: unknown policy role")
        (match (io.try-file-exists? (& source))
          [(io.OkIoBool exists)
            (if exists
              unit
              (begin
                (io.eprintln
                  "dependency boundary: stale policy path {}"
                  (& source))
                (fail "missing policy source")))]
          [(io.ErrIoBool error) (fail (io.error-message error))])
        (if (string.eq (& role) "core")
          (begin
            (require
              (string.eq (& source) root)
              "dependency boundary: core row does not match the root")
            (set! core-count (+ core-count 1)))
          unit)
        (strings.push-ref! (&mut paths) source)
        (strings.push-ref! (&mut roles) role)
        (set! (array-ref seen index) false)
        (set! index (+ index 1))))
    (require
      (= core-count 1)
      "dependency boundary: policy requires exactly one core root")
    (Policy paths roles seen)))

(define (observe-source! [policy : (&mut policy Policy)] [source : String]) : unit
  (let
    [normalized : String (fs.path-normalize (& source))]
    [index : i64 (index-of (& policy.paths) (& normalized))]
    (if (< index 0)
      (begin
        (io.eprintln
          "dependency boundary: unclassified resolved source {}"
          (& normalized))
        (fail "classify the new dependency and its architectural role"))
      unit)
    (if (string.eq (strings.get (& policy.roles) index "") "forbidden")
      (begin
        (io.eprintln
          "dependency boundary: forbidden resolved source {}"
          (& normalized))
        (fail "core IR depends on a consuming compiler layer"))
      unit)
    (set! (array-ref policy.seen index) true)))

(define (observe-event!
  [policy : (&mut policy Policy)]
  [space : (&mut space ConfigSpace)]
  [line : (& line str)]) : bool
  (let
    [event : json.JsonSeq (json-array (parse-json line))]
    [_shape : unit
      (require (= event.len 2) "dependency boundary: malformed compiler fact")]
    [kind : String
      (json-string (json.clone-json (& (array-ref event.slots 0))))]
    [value : String
      (json-string (json.clone-json (& (array-ref event.slots 1))))]
    (cond
      [(string.eq (& kind) "source")
        (observe-source! policy value)
        false]
      [(string.eq (& kind) "cfg")
        (require
          (> (string.string-length (& value)) 0)
          "dependency boundary: empty cfg name")
        (observe-cfg! space value)
        false]
      [(string.eq (& kind) "done")
        (require
          (= (string.string-length (& value)) 0)
          "dependency boundary: malformed terminal fact")
        true]
      [else (fail "dependency boundary: unknown compiler fact")])))

(define (observe-output!
  [policy : (&mut policy Policy)]
  [space : (&mut space ConfigSpace)]
  [output : (& output str)]) : unit
  (let
    [length : i64 (string.string-length output)]
    [start : i64 0]
    [index : i64 0]
    [done : bool false]
    (require
      (<= length 8388608)
      "dependency boundary: compiler fact output exceeds 8 MiB work limit")
    (while (< index length)
      (if (= (string.string-ref output index) '\n')
        (let
          [raw : String (string.substring output start (- index start))]
          [line : String (string.trim (& raw))]
          (require (not done) "dependency boundary: facts after terminal event")
          (require
            (> (string.string-length (& line)) 0)
            "dependency boundary: empty compiler fact")
          (set! done (observe-event! policy space (& line)))
          (set! start (+ index 1)))
        unit)
      (set! index (+ index 1)))
    (require
      (= start length)
      "dependency boundary: truncated compiler fact stream")
    (require
      done
      "dependency boundary: compiler did not finish frontend processing")))

(define (configuration-count [names : (& names strings.Vec)]) : i64
  (let
    [count : i64 1]
    [index : i64 0]
    (require
      (<= (strings.len names) 11)
      "dependency boundary: cfg space exceeds 4096-target/configuration-job work limit")
    (while (< index (strings.len names))
      (set! count (* count 2))
      (set! index (+ index 1)))
    count))

(define (worker-count) : i64
  (match (env.get "TYPELISP_CORE_IR_BOUNDARY_WORKERS")
    [(env.EnvSomeString raw)
      (let
        [parsed : i64 (string.>int (& raw))]
        (cond [(< parsed 1) 1] [(> parsed 8) 8] [else parsed]))]
    [(env.EnvNoString) 4]))

(define (build-inspector-command
  [inspector : (& inspector str)]
  [root : (& root str)]
  [names : (& names strings.Vec)]
  [mask : i64]
  [target : i64]) : process.ProcessCommand
  (let
    [command : process.ProcessCommand
      (process.command-with-arg
        (process.command
          (string.copy inspector)
          (process.args-single (string.copy root)))
        (if (= target 0)
          "linux-x86_64"
          "windows-x86_64"))]
    [bits : i64 mask]
    [index : i64 0]
    (while (< index (strings.len names))
      (when
        (= (% bits 2) 1)
        (set!
          command
          (process.command-with-arg command (strings.get names index ""))))
      (set! bits (/ bits 2))
      (set! index (+ index 1)))
    command))

;; Encode one inspector ProcessOutput into a self-delimiting String:
;;   "E" + error-message
;;   "O" + status + "\n" + stderr-len + "\n" + stderr + stdout
(define (run-inspector-encoded [mask : i64] [target : i64]) : String
  (let
    [command : process.ProcessCommand
      (build-inspector-command
        (& batch-inspector)
        (& batch-root)
        (& batch-cfg-names)
        mask
        target)]
    (match (process.run command)
      [(process.OkProcessOutput output)
        (let
          [status : i64 (process.output-status (& output))]
          [stderr : String (process.output-stderr (& output))]
          [stdout : String (process.output-stdout (& output))]
          (str_cat.str-cat
            "O"
            (string.int->string status)
            "\n"
            (string.int->string (string.string-length (& stderr)))
            "\n"
            stderr
            stdout))]
      [(process.ErrProcessOutput error)
        (str_cat.str-cat "E" (process.error-message error))])))

(define (observe-encoded-result!
  [policy : (&mut policy Policy)]
  [space : (&mut space ConfigSpace)]
  [mask : i64]
  [target : i64]
  [encoded : (& encoded str)]) : unit
  (let
    [total-len : i64 (string.string-length encoded)]
    (require (> total-len 0) "dependency boundary: empty worker result")
    (let
      [tag : char (string.string-ref encoded 0)]
      (if (= tag 'E')
        (fail (string.substring encoded 1 (- total-len 1)))
        (let
          [nl1 : i64 (string.index-of-byte encoded 1 (cast 10 : u8))]
          [_ok1 : unit
            (require (> nl1 1) "dependency boundary: malformed worker status")]
          [status-text : String (string.substring encoded 1 (- nl1 1))]
          [status : i64 (string.>int (& status-text))]
          [nl2 : i64 (string.index-of-byte encoded (+ nl1 1) (cast 10 : u8))]
          [_ok2 : unit
            (require
              (> nl2 (+ nl1 1))
              "dependency boundary: malformed worker stderr length")]
          [stderr-len-text : String
            (string.substring encoded (+ nl1 1) (- nl2 (+ nl1 1)))]
          [stderr-len : i64 (string.>int (& stderr-len-text))]
          [stderr-start : i64 (+ nl2 1)]
          [stdout-start : i64 (+ stderr-start stderr-len)]
          [_ok3 : unit
            (require
              (and (>= stderr-len 0) (<= stdout-start total-len))
              "dependency boundary: malformed worker payload")]
          [stderr : String (string.substring encoded stderr-start stderr-len)]
          [stdout : String
            (string.substring encoded stdout-start (- total-len stdout-start))]
          (when
            (!= status 0)
            (io.eprintln
              "dependency boundary: inspector failed for configuration {} target {} (exit {})"
              mask
              target
              status)
            (io.print-error stderr)
            (fail "canonical frontend processing failed"))
          (require
            (= (string.string-length (& stderr)) 0)
            "dependency boundary: unexpected inspector stderr")
          (observe-output! policy space (& stdout)))))))

(define (copy-string-vec [source : (& source strings.Vec)]) : strings.Vec
  (let
    [out : strings.Vec (strings.new)]
    [i : i64 0]
    (while (< i (strings.len source))
      (strings.push-ref! (&mut out) (strings.get source i ""))
      (set! i (+ i 1)))
    out))

(define (check [inspector : String] [root : String] [policy-path : String]) : i64
  (let
    [policy : Policy (read-policy policy-path (& root))]
    [space : ConfigSpace (ConfigSpace (strings.new) (strings.new))]
    [workers : i64 (worker-count)]
    [next-job : i64 0]
    [index : i64 0]
    ;; New names append stable bit positions. Previously visited assignments
    ;; already covered the new bits as false, so extending the mask range
    ;; explores the complete discovered boolean space without restarting jobs.
    ;; Dispatch pending (mask, target) pairs in parallel batches of `workers`
    ;; isolated inspector processes, then observe results in exact order.
    (set! batch-inspector (string.copy (& inspector)))
    (set! batch-root (string.copy (& root)))
    (while (< next-job (* (configuration-count (& space.names)) 2))
      (let
        [total-jobs : i64 (* (configuration-count (& space.names)) 2)]
        [remaining : i64 (- total-jobs next-job)]
        [batch-size : i64
          (if (< remaining workers)
            remaining
            workers)]
        (if (= batch-size 1)
          (let
            [mask : i64 (/ next-job 2)]
            [target : i64 (% next-job 2)]
            [command : process.ProcessCommand
              (build-inspector-command
                (& inspector)
                (& root)
                (& space.names)
                mask
                target)]
            (match (process.run command)
              [(process.OkProcessOutput output)
                (when
                  (!= (process.output-status (& output)) 0)
                  (io.eprintln
                    "dependency boundary: inspector failed for configuration {} target {} (exit {})"
                    mask
                    target
                    (process.output-status (& output)))
                  (io.print-error (process.output-stderr (& output)))
                  (fail "canonical frontend processing failed"))
                (require
                  (= (string.string-length (& output.stderr)) 0)
                  "dependency boundary: unexpected inspector stderr")
                (observe-output! (&mut policy) (&mut space) (& output.stdout))]
              [(process.ErrProcessOutput error)
                (fail (process.error-message error))])
            (set! next-job (+ next-job 1)))
          (let
            [handles : (Array MaybeWorker 8) (make-array MaybeWorker 8)]
            [results : (Array String 8) (make-array String 8)]
            [slot : i64 0]
            (set! batch-cfg-names (copy-string-vec (& space.names)))
            (while (< slot batch-size)
              (let
                [job-id : i64 (+ next-job slot)]
                [job-mask : i64 (/ job-id 2)]
                [job-target : i64 (% job-id 2)]
                (match (thread.spawn-string
                  (lambda () : String
                    (run-inspector-encoded job-mask job-target)))
                  [(thread.ThreadStringSpawnOk worker)
                    (set!
                      (array-ref handles slot)
                      (MaybeWorker.HasWorker worker))]
                  [(thread.ThreadStringSpawnErr message) (fail message)]))
              (set! slot (+ slot 1)))
            ;; Join every spawned worker before validating so no worker outlives
            ;; an early fail/exit or reads batch globals during teardown.
            (set! slot 0)
            (while (< slot batch-size)
              (match (replace! (array-ref handles slot) (MaybeWorker.NoWorker))
                [(MaybeWorker.HasWorker worker)
                  (match (thread.join-string worker)
                    [(thread.ThreadStringJoinOk encoded)
                      (set! (array-ref results slot) encoded)]
                    [(thread.ThreadStringJoinErr message) (fail message)])]
                [(MaybeWorker.NoWorker)
                  (fail "dependency boundary: missing worker handle")])
              (set! slot (+ slot 1)))
            (set! slot 0)
            (while (< slot batch-size)
              (let
                [job-id : i64 (+ next-job slot)]
                [job-mask : i64 (/ job-id 2)]
                [job-target : i64 (% job-id 2)]
                (observe-encoded-result!
                  (&mut policy)
                  (&mut space)
                  job-mask
                  job-target
                  (& (array-ref results slot))))
              (set! slot (+ slot 1)))
            (set! next-job (+ next-job batch-size))))))
    (set! index 0)
    (while (< index (strings.len (& policy.paths)))
      (unless
        (or
          (array-ref policy.seen index)
          (string.eq (strings.get (& policy.roles) index "") "forbidden"))
        (io.eprintln
          "dependency boundary: stale unreachable policy source {}"
          (strings.get (& policy.paths) index ""))
        (fail "remove the stale support classification"))
      (set! index (+ index 1)))
    (io.println
      "core IR dependency boundary passed: {} target/configuration jobs, {} cfg names"
      next-job
      (strings.len (& space.names)))
    0))