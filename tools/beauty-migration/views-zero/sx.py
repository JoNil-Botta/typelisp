"""Minimal TypeLisp s-expression reader with source offsets.

Node layouts (lists for speed):
  list/vec : [kind('L'|'V'), start, end, children]
  atom     : ['A', start, end, text]
  string   : ['S', start, end, text]
  char     : ['C', start, end, text]
  prefix   : ['P', start, end, prefix_text, child]   (quote/quasiquote/unquote, or a postfix `.field`)
parse(text) returns the top-level nodes.
"""
import re

TOK = re.compile(r"""
 (?P<ws>\s+)
|(?P<com>;[^\n]*)
|(?P<lp>\()
|(?P<rp>\))
|(?P<lb>\[)
|(?P<rb>\])
|(?P<str>"(?:\\.|[^"\\])*")
|(?P<chr>'(?:\\.|[^\\\n])')
|(?P<ca>,@)
|(?P<pre>[,`'])
|(?P<atom>[^\s()\[\];"'`,]+)
""", re.X | re.S)


def parse(text):
    stack = [['L', 0, len(text), []]]
    pending = []  # (depth, prefix node) awaiting a child
    pos = 0
    n = len(text)
    m = TOK.match

    def attach(node):
        sibs = stack[-1][3]
        # a postfix field read `(expr).k` right after a list or prefix node: one node
        if node[0] == 'A' and node[3].startswith('.') and len(node[3]) > 1 and sibs \
                and sibs[-1][0] in ('L', 'P') and sibs[-1][2] == node[1]:
            prev = sibs.pop()
            sibs.append(['P', prev[1], node[2], node[3], prev])
            return
        while pending and pending[-1][0] == len(stack):
            _, p = pending.pop()
            p[4] = node
            p[2] = node[2]
            node = p
        stack[-1][3].append(node)

    while pos < n:
        mo = m(text, pos)
        if not mo:
            raise ValueError('lex error at %d: %r' % (pos, text[pos:pos + 20]))
        k = mo.lastgroup
        s, e = mo.start(), mo.end()
        pos = e
        if k == 'ws' or k == 'com':
            continue
        if k == 'lp' or k == 'lb':
            stack.append(['L' if k == 'lp' else 'V', s, None, []])
        elif k == 'rp' or k == 'rb':
            if len(stack) == 1:
                raise ValueError('unbalanced close at %d' % s)
            node = stack.pop()
            node[2] = e
            attach(node)
        elif k == 'str':
            attach(['S', s, e, text[s:e]])
        elif k == 'chr':
            attach(['C', s, e, text[s:e]])
        elif k == 'ca' or k == 'pre':
            pending.append((len(stack), ['P', s, None, text[s:e], None]))
        else:
            attach(['A', s, e, text[s:e]])
    if len(stack) != 1:
        raise ValueError('unbalanced: %d open' % (len(stack) - 1))
    return stack[0][3]
