;; The C ABI is a property of the callee's type: a call through any
;; `(CFunc ...)` value lends its arguments (SPEC 4.3), exactly as a direct
;; extern call does. The value may be a global, an extern data symbol, a
;; parameter, a local, a field (also behind a reference) or a call result, and
;; the argument a field, tuple or array element, a struct or a cleanup owner;
;; the calls also run in match arms and loops. Checked only: the callees are C
;; symbols.
(extern (first) : (CFunc non-null (-> String i64)) (:symbol "tl_callee_first"))
(extern (direct [s : String]) : i64 (:symbol "tl_direct"))
(extern data-fn (:symbol "tl_data_fn") : (CFunc non-null (-> String i64)))

(define selected : (CFunc non-null (-> String i64))
  (first))

(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct Handle
  (:cleanup cleanup-handle)
  (fd i64 (:cleanup close-fd)))

(defstruct Holder
  (callback (CFunc non-null (-> String i64))))

(defstruct Named
  (name String)
  (id i64))

(defenum Pick
  (A)
  (B))

(define (sources
  [callback : (CFunc non-null (-> String i64))]
  [h : Holder]
  [shared : (& Holder)]
  [s : String]) : i64
  (let
    [local : (CFunc non-null (-> String i64)) (first)]
    (+
      (direct s)
      (direct s)
      (selected s)
      (selected s)
      (data-fn s)
      (data-fn s)
      (callback s)
      (callback s)
      (local s)
      (local s)
      (h.callback s)
      (h.callback s)
      (shared.callback s)
      (shared.callback s)
      ((first) s)
      ((first) s))))

(define (arguments
  [callback : (CFunc non-null (-> String i64))]
  [n : Named]
  [record : (CFunc non-null (-> Named i64))]) : i64
  (let
    [pair : (Tuple String i64) (tuple "x" 1)]
    [items : (Array String 2) (array "x" "y")]
    (+
      (callback n.name)
      (callback n.name)
      (callback (tuple-ref pair 0))
      (callback (tuple-ref pair 0))
      (callback (array-ref items 0))
      (callback (array-ref items 0))
      (record n)
      (record n))))

(define (control
  [callback : (CFunc non-null (-> String i64))]
  [p : Pick]
  [s : String]) : i64
  (let
    [n : i64 0]
    [total : i64
      (match p
        [(Pick.A) (callback s)]
        [(Pick.B) (callback s)])]
    (begin
      (while (< n 3)
        (begin
          (set! total (+ total (callback s)))
          (set! n (+ n 1))))
      (+ total (callback s)))))

;; A lent owner is still the caller's: a `with` owner's cleanup runs at its
;; scope exit, and a `let` owner is discharged afterwards.
(define (owners [callback : (CFunc non-null (-> Handle i64))]) : i64
  (+
    (with ([h (Handle 1) cleanup-handle]) (+ (callback h) (callback h)))
    (let
      [g : Handle (Handle 2)]
      [used : i64 (+ (callback g) (callback g))]
      (begin
        (cleanup-handle g)
        used))))

(define (unchecked
  [callback : (CFunc unsafe-non-null (-> String i64))]
  [s : String]) : i64
  (unsafe
    (+ (callback s) (callback s))))

(define (main) : i64
  0)