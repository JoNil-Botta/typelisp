#!/usr/bin/env python3
# sexp.py: a position-keeping s-expression reader for TypeLisp sources.
# parse(text) -> list of top-level nodes. A node is a dict:
#   {'k': 'list'|'vec'|'atom'|'str', 'a': start, 'b': end (exclusive),
#    'c': children (lists/vecs), 't': text (atoms)}
# Comments (`;` to end of line) and `#\x` character literals are handled.


def parse(text):
    n = len(text)
    i = 0
    stack = [{'k': 'root', 'a': 0, 'c': []}]
    while i < n:
        ch = text[i]
        if ch == ';':
            while i < n and text[i] != '\n':
                i += 1
            continue
        if ch in ' \t\r\n':
            i += 1
            continue
        if ch == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == '\\':
                    j += 1
                j += 1
            stack[-1]['c'].append({'k': 'str', 'a': i, 'b': j + 1, 't': text[i:j + 1]})
            i = j + 1
            continue
        if ch in '([':
            node = {'k': 'list' if ch == '(' else 'vec', 'a': i, 'c': []}
            stack[-1]['c'].append(node)
            stack.append(node)
            i += 1
            continue
        if ch in ')]':
            node = stack.pop()
            node['b'] = i + 1
            i += 1
            continue
        if ch == '#' and i + 1 < n and text[i + 1] == '\\':
            j = i + 3
            while j < n and text[j] not in ' \t\r\n()[]':
                j += 1
            stack[-1]['c'].append({'k': 'atom', 'a': i, 'b': j, 't': text[i:j]})
            i = j
            continue
        if ch in "`',@":
            i += 1
            if ch == ',' and i < n and text[i] == '@':
                i += 1
            continue
        j = i
        while j < n and text[j] not in ' \t\r\n()[];"':
            j += 1
        stack[-1]['c'].append({'k': 'atom', 'a': i, 'b': j, 't': text[i:j]})
        i = j
    return stack[0]['c']


def head(node):
    if node['k'] == 'list' and node['c'] and node['c'][0]['k'] == 'atom':
        return node['c'][0]['t']
    return None


def walk(node):
    yield node
    for c in node.get('c', []):
        yield from walk(c)


def define_name(node):
    # (define (name params...) : T body...) -> name
    if head(node) in ('define', 'defmacro') and len(node['c']) > 1:
        sig = node['c'][1]
        if sig['k'] == 'list' and sig['c'] and sig['c'][0]['k'] == 'atom':
            return sig['c'][0]['t']
    return None


def toplevel_defines(nodes):
    # Defines at top level and inside (cfg test ...) wrappers.
    for node in nodes:
        name = define_name(node)
        if name:
            yield name, node
        elif head(node) == 'cfg':
            for c in node['c'][2:]:
                name = define_name(c)
                if name:
                    yield name, c
