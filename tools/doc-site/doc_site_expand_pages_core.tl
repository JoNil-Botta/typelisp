;; doc_site_expand_pages_core.tl - Generated-module API section post-processing.
(import stdlib.io)
(import stdlib.fs)
(import stdlib.string)
(import stdlib.str_cat)

(define doc-site-expand-status-ok : i64
  0)

(define (doc-site-expand-path-join [left : String] [right : String]) : String
  (fs.path-join (& left) (& right)))

(define (doc-site-expand-prefix-at?
  [text : String]
  [prefix : String]
  [start : i64]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [prefix-len : i64 (string.string-length prefix)]
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let
          [i : i64 0]
          [ok : bool true]
          (begin
            (while (and ok (< i prefix-len))
              (if (=
                (string.string-ref text (+ start i))
                (string.string-ref prefix i))
                (set! i (+ i 1))
                (set! ok false)))
            ok))))))

(define (doc-site-expand-find-prefix
  [text : String]
  [prefix : String]
  [from : i64]) : i64
  (let
    [i : i64 from]
    [n : i64 (string.string-length text)]
    [found : i64 n]
    (begin
      (while (and (< i n) (= found n))
        (begin
          (if (doc-site-expand-prefix-at? text prefix i)
            (set! found i)
            unit)
          (set! i (+ i 1))))
      found)))

(define (doc-site-expand-string-contains? [text : String] [needle : String]) : bool
  (< (doc-site-expand-find-prefix text needle 0) (string.string-length text)))

(define (doc-site-expand-anchor-char? [c : char]) : bool
  (or
    (and (>= c 'A') (<= c 'Z'))
    (and (>= c 'a') (<= c 'z'))
    (and (>= c '0') (<= c '9'))
    (= c '-')
    (= c '_')))

(define (doc-site-expand-anchor [name : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string.string-length name)]
    [out : String "tl-"]
    (begin
      (while (< i n)
        (let
          [c : char (string.string-ref name i)]
          (begin
            (if (doc-site-expand-anchor-char? c)
              (set! out (str_cat.str-cat out (string.substring name i 1)))
              (set!
                out
                (str_cat.str-cat out "-" (string.int->string (cast c : i64)))))
            (set! i (+ i 1)))))
      out)))

(define (doc-site-expand-html-escape-one [text : String] [idx : i64]) : String
  (let
    [c : char (string.string-ref text idx)]
    (cond
      [(= c '&') "&amp;"]
      [(= c '<') "&lt;"]
      [(= c '>') "&gt;"]
      [(= c '"') "&quot;"]
      [else (string.substring text idx 1)])))

(define (doc-site-expand-html-escape [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string.string-length text)]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (set!
            out
            (str_cat.str-cat out (doc-site-expand-html-escape-one text i)))
          (set! i (+ i 1))))
      out)))

(define (doc-site-expand-code-block [source : String]) : String
  (str_cat.str-cat
    "<pre><code class=\"language-typelisp\">"
    (doc-site-expand-html-escape source)
    "</code></pre>\n"))

(define (doc-site-expand-doc-block [doc-text : String]) : String
  (if (= (string.string-length doc-text) 0)
    "<p class=\"tl-doc-empty\">No item docs.</p>\n"
    (str_cat.str-cat
      "<div class=\"tl-doc-item-text\"><p>"
      (doc-site-expand-html-escape doc-text)
      "</p></div>\n")))

(define (doc-site-expand-nav-entry [name : String]) : String
  (let
    [anchor : String (doc-site-expand-anchor name)]
    (str_cat.str-cat
      "<li><a href=\"#"
      anchor
      "\"><code>"
      (doc-site-expand-html-escape name)
      "</code></a></li>\n")))

(define (doc-site-expand-item
  [kind : String]
  [name : String]
  [signature : String]
  [doc-text : String]) : String
  (let
    [anchor : String (doc-site-expand-anchor name)]
    (str_cat.str-cat
      "<a id=\""
      anchor
      "\"></a>\n<section class=\"tl-doc-item\">\n<h3><a href=\"#"
      anchor
      "\">"
      (doc-site-expand-html-escape name)
      "</a></h3>\n<dl class=\"tl-doc-meta\"><dt>Kind</dt><dd>"
      (doc-site-expand-html-escape kind)
      "</dd></dl>\n"
      (doc-site-expand-code-block signature)
      (doc-site-expand-doc-block doc-text)
      "</section>\n")))

(define (doc-site-expand-module-section
  [module-name : String]
  [nav : String]
  [items : String]) : String
  (let
    [anchor : String (doc-site-expand-anchor module-name)]
    [escaped : String (doc-site-expand-html-escape module-name)]
    (str_cat.str-cat
      "<section class=\"tl-doc-module\" id=\""
      anchor
      "\">\n<h2><a href=\"#"
      anchor
      "\">"
      escaped
      "</a></h2>\n<p class=\"tl-doc-source\"><code>"
      escaped
      "</code></p>\n<div class=\"tl-doc-module-text\"><p>Generated module API.</p></div>\n"
      "<nav class=\"tl-doc-item-nav\" aria-label=\"Declarations\">\n<h3>Declarations</h3>\n<ul>\n"
      nav
      "</ul>\n</nav>\n"
      items
      "</section>\n")))

;; Keep this tool independent of src/doc_expand.tl: importing the compiler-backed
;; expander here pulls the full compiler stack into the docs post-processor.
(define (doc-site-expand-vector-nav) : String
  (str_cat.str-cat
    (doc-site-expand-nav-entry "import")
    (doc-site-expand-nav-entry "Vec")
    (doc-site-expand-nav-entry "Pop")
    (doc-site-expand-nav-entry "slots")
    (doc-site-expand-nav-entry "slots-mut")
    (doc-site-expand-nav-entry "len")
    (doc-site-expand-nav-entry "len-mut")
    (doc-site-expand-nav-entry "capacity")
    (doc-site-expand-nav-entry "is-empty?")
    (doc-site-expand-nav-entry "with-capacity")
    (doc-site-expand-nav-entry "new")
    (doc-site-expand-nav-entry "get")
    (doc-site-expand-nav-entry "last")
    (doc-site-expand-nav-entry "set")
    (doc-site-expand-nav-entry "copy-range!")
    (doc-site-expand-nav-entry "grow")
    (doc-site-expand-nav-entry "push")
    (doc-site-expand-nav-entry "pop")
    (doc-site-expand-nav-entry "from-array")
    (doc-site-expand-nav-entry "to-array")
    (doc-site-expand-nav-entry "extend-from")
    (doc-site-expand-nav-entry "extend")
    (doc-site-expand-nav-entry "reverse-range!")
    (doc-site-expand-nav-entry "reverse!")
    (doc-site-expand-nav-entry "fold-from")
    (doc-site-expand-nav-entry "fold")
    (doc-site-expand-nav-entry "map-build-from")
    (doc-site-expand-nav-entry "map-from")
    (doc-site-expand-nav-entry "map")
    (doc-site-expand-nav-entry "value-eq?")
    (doc-site-expand-nav-entry "contains-from?")
    (doc-site-expand-nav-entry "contains?")))

(define (doc-site-expand-vector-items [type-name : String] [alias : String]) : String
  (str_cat.str-cat
    (doc-site-expand-item
      "generated-module-import"
      "import"
      (str_cat.str-cat "(import (vector.vector " type-name ") as " alias ")")
      "Concrete generated-module import that produced this API.")
    (doc-site-expand-item
      "defstruct"
      "Vec"
      (str_cat.str-cat
        "(defstruct Vec\n  (slots (Array "
        type-name
        "))\n  (len i64))")
      "")
    (doc-site-expand-item
      "defenum"
      "Pop"
      (str_cat.str-cat "(defenum Pop\n  (Empty)\n  (Ok " type-name "))")
      "")
    (doc-site-expand-item
      "define-function"
      "slots"
      (str_cat.str-cat
        "(define (slots [v : (& v Vec)]) : (& v (Array "
        type-name
        ")) ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "slots-mut"
      (str_cat.str-cat
        "(define (slots-mut [v : (&mut v Vec)]) : (&mut v (Array "
        type-name
        ")) ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "len"
      "(define (len [v : (& v Vec)]) : i64 ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "len-mut"
      "(define (len-mut [v : (&mut v Vec)]) : i64 ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "capacity"
      "(define (capacity [v : (& v Vec)]) : i64 ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "is-empty?"
      "(define (is-empty? [v : (& v Vec)]) : bool ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "with-capacity"
      "(define (with-capacity [capacity : i64]) : Vec ...)"
      "")
    (doc-site-expand-item "define-function" "new" "(define (new) : Vec ...)" "")
    (doc-site-expand-item
      "define-function"
      "get"
      (str_cat.str-cat
        "(define (get [v : (& v Vec)] [index : i64] [fallback : "
        type-name
        "]) : "
        type-name
        " ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "last"
      (str_cat.str-cat
        "(define (last [v : (& v Vec)] [fallback : "
        type-name
        "]) : "
        type-name
        " ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "set"
      (str_cat.str-cat
        "(define (set [v : (&mut v Vec)] [index : i64] [value : "
        type-name
        "]) : unit ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "copy-range!"
      (str_cat.str-cat
        "(define (copy-range! [dst : (&mut dst (Array "
        type-name
        "))] [src : (& src (Array "
        type-name
        "))] [index : i64] [count : i64]) : unit ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "grow"
      "(define (grow [v : (&mut v Vec)]) : unit ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "push"
      (str_cat.str-cat
        "(define (push [v : (&mut v Vec)] [value : "
        type-name
        "]) : unit ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "pop"
      "(define (pop [v : (&mut v Vec)]) : Pop ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "from-array"
      (str_cat.str-cat
        "(define (from-array [src : (& src (Array "
        type-name
        "))] [count : i64]) : Vec ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "to-array"
      (str_cat.str-cat
        "(define (to-array [v : (& v Vec)]) : (Array "
        type-name
        ") ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "extend-from"
      (str_cat.str-cat
        "(define (extend-from [v : (&mut v Vec)] [src : (& src (Array "
        type-name
        "))] [index : i64] [count : i64]) : unit ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "extend"
      (str_cat.str-cat
        "(define (extend [v : (&mut v Vec)] [src : (& src (Array "
        type-name
        "))] [count : i64]) : unit ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "reverse-range!"
      (str_cat.str-cat
        "(define (reverse-range! [items : (&mut items (Array "
        type-name
        "))] [lo : i64] [hi : i64]) : unit ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "reverse!"
      "(define (reverse! [v : (&mut v Vec)]) : unit ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "fold-from"
      (str_cat.str-cat
        "(define (fold-from [v : (& v Vec)] [index : i64] [acc : "
        type-name
        "] [step : (-> "
        type-name
        " "
        type-name
        " "
        type-name
        ")]) : "
        type-name
        " ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "fold"
      (str_cat.str-cat
        "(define (fold [v : (& v Vec)] [acc : "
        type-name
        "] [step : (-> "
        type-name
        " "
        type-name
        " "
        type-name
        ")]) : "
        type-name
        " ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "map-build-from"
      (str_cat.str-cat
        "(define (map-build-from [v : (& v Vec)] [index : i64] [out : (&mut out Vec)] [mapper : (-> "
        type-name
        " "
        type-name
        ")]) : unit ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "map-from"
      (str_cat.str-cat
        "(define (map-from [v : (& v Vec)] [index : i64] [mapper : (-> "
        type-name
        " "
        type-name
        ")]) : Vec ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "map"
      (str_cat.str-cat
        "(define (map [v : (& v Vec)] [mapper : (-> "
        type-name
        " "
        type-name
        ")]) : Vec ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "value-eq?"
      (str_cat.str-cat
        "(define (value-eq? [a : "
        type-name
        "] [b : "
        type-name
        "]) : bool ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "contains-from?"
      (str_cat.str-cat
        "(define (contains-from? [v : (& v Vec)] [x : "
        type-name
        "] [index : i64]) : bool ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "contains?"
      (str_cat.str-cat
        "(define (contains? [v : (& v Vec)] [x : "
        type-name
        "]) : bool ...)")
      "")))

(define (doc-site-expand-vector-module [type-name : String] [alias : String]) : String
  (doc-site-expand-module-section
    (str_cat.str-cat "stdlib.vector.generated." type-name)
    (doc-site-expand-vector-nav)
    (doc-site-expand-vector-items type-name alias)))

(define (doc-site-expand-vector-sections) : String
  (str_cat.str-cat
    (doc-site-expand-vector-module "i64" "ivec")
    (doc-site-expand-vector-module "String" "svec")))

(define (doc-site-expand-queue-nav) : String
  (str_cat.str-cat
    (doc-site-expand-nav-entry "import")
    (doc-site-expand-nav-entry "Deque")
    (doc-site-expand-nav-entry "Pop")
    (doc-site-expand-nav-entry "slots")
    (doc-site-expand-nav-entry "slots-mut")
    (doc-site-expand-nav-entry "head")
    (doc-site-expand-nav-entry "len")
    (doc-site-expand-nav-entry "len-mut")
    (doc-site-expand-nav-entry "capacity")
    (doc-site-expand-nav-entry "is-empty?")
    (doc-site-expand-nav-entry "with-capacity")
    (doc-site-expand-nav-entry "new")
    (doc-site-expand-nav-entry "next-index")
    (doc-site-expand-nav-entry "prev-index")
    (doc-site-expand-nav-entry "physical-index-from")
    (doc-site-expand-nav-entry "physical-index")
    (doc-site-expand-nav-entry "get")
    (doc-site-expand-nav-entry "peek-front")
    (doc-site-expand-nav-entry "peek-back")
    (doc-site-expand-nav-entry "copy-live!")
    (doc-site-expand-nav-entry "grow")
    (doc-site-expand-nav-entry "push-back!")
    (doc-site-expand-nav-entry "push-front!")
    (doc-site-expand-nav-entry "pop-front!")
    (doc-site-expand-nav-entry "pop-back!")))

(define (doc-site-expand-queue-items [type-name : String] [alias : String]) : String
  (str_cat.str-cat
    (doc-site-expand-item
      "generated-module-import"
      "import"
      (str_cat.str-cat "(import (queue.deque " type-name ") as " alias ")")
      "Concrete generated-module import that produced this API.")
    (doc-site-expand-item
      "defstruct"
      "Deque"
      (str_cat.str-cat
        "(defstruct Deque\n  (slots (Array "
        type-name
        "))\n  (head i64)\n  (len i64))")
      "")
    (doc-site-expand-item
      "defenum"
      "Pop"
      (str_cat.str-cat "(defenum Pop\n  (Empty)\n  (Ok " type-name "))")
      "")
    (doc-site-expand-item
      "define-function"
      "slots"
      (str_cat.str-cat
        "(define (slots [q : (& q Deque)]) : (& q (Array "
        type-name
        ")) ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "slots-mut"
      (str_cat.str-cat
        "(define (slots-mut [q : (&mut q Deque)]) : (&mut q (Array "
        type-name
        ")) ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "head"
      "(define (head [q : (& q Deque)]) : i64 ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "len"
      "(define (len [q : (& q Deque)]) : i64 ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "len-mut"
      "(define (len-mut [q : (&mut q Deque)]) : i64 ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "capacity"
      "(define (capacity [q : (& q Deque)]) : i64 ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "is-empty?"
      "(define (is-empty? [q : (& q Deque)]) : bool ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "with-capacity"
      "(define (with-capacity [capacity : i64]) : Deque ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "new"
      "(define (new) : Deque ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "next-index"
      "(define (next-index [index : i64] [capacity : i64]) : i64 ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "prev-index"
      "(define (prev-index [index : i64] [capacity : i64]) : i64 ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "physical-index-from"
      "(define (physical-index-from [head : i64] [capacity : i64] [offset : i64]) : i64 ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "physical-index"
      "(define (physical-index [q : (& q Deque)] [offset : i64]) : i64 ...)"
      "")
    (doc-site-expand-item
      "define-function"
      "get"
      (str_cat.str-cat
        "(define (get [q : (& q Deque)] [index : i64] [fallback : "
        type-name
        "]) : "
        type-name
        " ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "peek-front"
      (str_cat.str-cat
        "(define (peek-front [q : (& q Deque)] [fallback : "
        type-name
        "]) : "
        type-name
        " ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "peek-back"
      (str_cat.str-cat
        "(define (peek-back [q : (& q Deque)] [fallback : "
        type-name
        "]) : "
        type-name
        " ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "copy-live!"
      (str_cat.str-cat
        "(define (copy-live! [dst : (&mut dst (Array "
        type-name
        "))] [src : (& src (Array "
        type-name
        "))] [head : i64] [capacity : i64] [count : i64] [index : i64]) : unit ...)")
      "")
    (doc-site-expand-item
      "define-function"
      "grow"
      "(define (grow [q : (&mut q Deque)]) : unit ...)"
      "")
    (doc-site-expand-item
      "defmacro"
      "push-back!"
      (str_cat.str-cat
        "(defmacro (push-back! [place : comptime.Expr] [value : "
        type-name
        "]) : unit ...)")
      "Mutates a caller-owned storage place by expanding to `push-back-ref!` with an explicit mutable borrow.")
    (doc-site-expand-item
      "defmacro"
      "push-front!"
      (str_cat.str-cat
        "(defmacro (push-front! [place : comptime.Expr] [value : "
        type-name
        "]) : unit ...)")
      "Mutates a caller-owned storage place by expanding to `push-front-ref!` with an explicit mutable borrow.")
    (doc-site-expand-item
      "defmacro"
      "pop-front!"
      "(defmacro (pop-front! [place : comptime.Expr]) : Pop ...)"
      "Mutates a caller-owned storage place by expanding to `pop-front-ref!` with an explicit mutable borrow.")
    (doc-site-expand-item
      "defmacro"
      "pop-back!"
      "(defmacro (pop-back! [place : comptime.Expr]) : Pop ...)"
      "Mutates a caller-owned storage place by expanding to `pop-back-ref!` with an explicit mutable borrow.")))

(define (doc-site-expand-queue-module [type-name : String] [alias : String]) : String
  (doc-site-expand-module-section
    (str_cat.str-cat "stdlib.queue.deque.generated." type-name)
    (doc-site-expand-queue-nav)
    (doc-site-expand-queue-items type-name alias)))

(define (doc-site-expand-queue-sections) : String
  (doc-site-expand-queue-module "i64" "deque_i64"))

(define (doc-site-expand-generated-sections [source : String]) : String
  (cond
    [(string.eq source "stdlib/vector.tl") (doc-site-expand-vector-sections)]
    [(string.eq source "stdlib/queue.tl") (doc-site-expand-queue-sections)]
    [else ""]))

(define (doc-site-expand-insert-before-main-close
  [html : String]
  [insert : String]) : String
  (let
    [marker : String "</main>"]
    [n : i64 (string.string-length html)]
    [idx : i64 (doc-site-expand-find-prefix html marker 0)]
    (if (< idx n)
      (str_cat.str-cat
        (string.substring html 0 idx)
        insert
        (string.substring html idx (- n idx)))
      (str_cat.str-cat html insert ""))))

(define (doc-site-expand-page
  [site-dir : String]
  [source : String]
  [output : String]) : unit
  (let
    [sections : String (doc-site-expand-generated-sections source)]
    (if (= (string.string-length sections) 0)
      unit
      (let
        [path : String (doc-site-expand-path-join site-dir output)]
        [status : i64 (io.read-file-status path)]
        (if (= status doc-site-expand-status-ok)
          (let
            [html : String (io.read-file path)]
            (if (doc-site-expand-string-contains?
              html
              "generated-module-import")
              unit
              (io.write-file
                path
                (doc-site-expand-insert-before-main-close html sections))))
          (io.panic (str_cat.str-cat "doc-site-expand: missing page: " path "")))))))

;; Only modules with generated-module sections need post-processing, so this
;; walks that set instead of restating the site's stdlib module list. The site
;; module list has exactly one definition, in doc_site_core.tl, derived from the
;; `stdlib/` directory.
(define (doc-site-expand-pages [site-dir : String]) : i64
  (begin
    (doc-site-expand-page site-dir "stdlib/vector.tl" "stdlib-vector.html")
    (doc-site-expand-page site-dir "stdlib/queue.tl" "stdlib-queue.html")
    0))