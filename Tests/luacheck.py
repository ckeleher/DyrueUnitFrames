#!/usr/bin/env python3
"""Offline Lua 5.1 structural checker.

No Lua interpreter is available on this machine, so this tokenises Lua 5.1
(handling long strings/comments, short strings with escapes, numbers, names)
and verifies block and bracket balance.  It catches the overwhelming majority
of hand-written-Lua slips: missing/extra `end`, unterminated strings, stray
brackets, `then`/`do` omissions.

Usage: python luacheck.py <path> [<path> ...]
"""
import sys
import os

KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
    "true", "until", "while",
}


class LuaError(Exception):
    def __init__(self, line, msg):
        super().__init__(msg)
        self.line = line
        self.msg = msg


def _long_bracket(src, i):
    """If src[i:] starts a long bracket `[==[`, return (level, index_after)."""
    if src[i] != "[":
        return None
    j = i + 1
    level = 0
    while j < len(src) and src[j] == "=":
        level += 1
        j += 1
    if j < len(src) and src[j] == "[":
        return level, j + 1
    return None


def _skip_long(src, i, level, line, what):
    close = "]" + "=" * level + "]"
    end = src.find(close, i)
    if end == -1:
        raise LuaError(line, "unterminated long %s" % what)
    return end + len(close), line + src.count("\n", i, end)


def tokenize(src):
    """Yield (kind, value, line). kind in {name, keyword, string, number, op}."""
    i, n, line = 0, len(src), 1
    if src.startswith("#"):  # shebang
        i = src.find("\n")
        i = n if i == -1 else i
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c in " \t\r\v\f":
            i += 1
            continue
        # comments
        if src.startswith("--", i):
            lb = _long_bracket(src, i + 2)
            if lb:
                level, after = lb
                i, line = _skip_long(src, after, level, line, "comment")
            else:
                j = src.find("\n", i)
                i = n if j == -1 else j
            continue
        # long strings
        lb = _long_bracket(src, i)
        if lb:
            level, after = lb
            start_line = line
            i, line = _skip_long(src, after, level, line, "string")
            yield ("string", "", start_line)
            continue
        # short strings
        if c in "\"'":
            j = i + 1
            while True:
                if j >= n:
                    raise LuaError(line, "unterminated string")
                d = src[j]
                if d == "\\":
                    if j + 1 < n and src[j + 1] == "\n":
                        line += 1
                    j += 2
                    continue
                if d == "\n":
                    raise LuaError(line, "unterminated string (newline in string)")
                if d == c:
                    j += 1
                    break
                j += 1
            yield ("string", src[i:j], line)
            i = j
            continue
        # numbers
        if c.isdigit() or (c == "." and i + 1 < n and src[i + 1].isdigit()):
            j = i
            if src.startswith(("0x", "0X"), i):
                j = i + 2
                while j < n and (src[j] in "0123456789abcdefABCDEF"):
                    j += 1
            else:
                seen_e = False
                while j < n:
                    d = src[j]
                    if d.isdigit() or d == ".":
                        j += 1
                    elif d in "eE" and not seen_e:
                        seen_e = True
                        j += 1
                        if j < n and src[j] in "+-":
                            j += 1
                    else:
                        break
            yield ("number", src[i:j], line)
            i = j
            continue
        # names / keywords
        if c.isalpha() or c == "_":
            j = i
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            word = src[i:j]
            yield ("keyword" if word in KEYWORDS else "name", word, line)
            i = j
            continue
        # operators
        for op in ("...", "==", "~=", "<=", ">=", "..", "::"):
            if src.startswith(op, i):
                yield ("op", op, line)
                i += len(op)
                break
        else:
            yield ("op", c, line)
            i += 1


PAIRS = {")": "(", "]": "[", "}": "{"}


def check(src, path):
    """Return a list of problem strings (empty if the file looks structurally sound)."""
    problems = []
    stack = []          # block stack: (kind, line); kind in if/for/while/do/function/repeat
    pending = []        # for/while awaiting `do`, if/elseif awaiting `then`
    brackets = []       # (char, line)

    def top_block():
        return stack[-1][0] if stack else None

    try:
        for kind, val, line in tokenize(src):
            if kind == "op":
                if val in "([{":
                    brackets.append((val, line))
                elif val in PAIRS:
                    if not brackets:
                        problems.append("%s:%d: unexpected '%s'" % (path, line, val))
                    elif brackets[-1][0] != PAIRS[val]:
                        problems.append(
                            "%s:%d: '%s' closes '%s' opened at line %d"
                            % (path, line, val, brackets[-1][0], brackets[-1][1]))
                        brackets.pop()
                    else:
                        brackets.pop()
                continue
            if kind != "keyword":
                continue
            if val == "function":
                stack.append(("function", line))
            elif val == "if":
                stack.append(("if", line))
                pending.append(("then", line))
            elif val == "elseif":
                if top_block() != "if":
                    problems.append("%s:%d: 'elseif' outside an 'if' block" % (path, line))
                pending.append(("then", line))
            elif val == "else":
                if top_block() != "if":
                    problems.append("%s:%d: 'else' outside an 'if' block" % (path, line))
            elif val == "then":
                if not pending or pending[-1][0] != "then":
                    problems.append("%s:%d: unexpected 'then'" % (path, line))
                else:
                    pending.pop()
            elif val in ("for", "while"):
                stack.append((val, line))
                pending.append(("do", line))
            elif val == "do":
                if pending and pending[-1][0] == "do":
                    pending.pop()          # closes the for/while header
                else:
                    stack.append(("do", line))
            elif val == "repeat":
                stack.append(("repeat", line))
            elif val == "until":
                if top_block() != "repeat":
                    problems.append("%s:%d: 'until' without matching 'repeat'" % (path, line))
                else:
                    stack.pop()
            elif val == "end":
                if not stack:
                    problems.append("%s:%d: 'end' with no open block" % (path, line))
                elif top_block() == "repeat":
                    problems.append(
                        "%s:%d: 'end' closing a 'repeat' from line %d (expected 'until')"
                        % (path, line, stack[-1][1]))
                    stack.pop()
                else:
                    stack.pop()
    except LuaError as e:
        problems.append("%s:%d: %s" % (path, e.line, e.msg))
        return problems

    for kind, line in stack:
        problems.append("%s:%d: unclosed '%s' block" % (path, line, kind))
    for ch, line in brackets:
        problems.append("%s:%d: unclosed '%s'" % (path, line, ch))
    for what, line in pending:
        problems.append("%s:%d: missing '%s'" % (path, line, what))
    return problems


def main(argv):
    targets = []
    for arg in argv:
        if os.path.isdir(arg):
            for root, dirs, files in os.walk(arg):
                dirs[:] = [d for d in dirs if d not in (".git", "Libs")]
                for f in sorted(files):
                    if f.endswith(".lua"):
                        targets.append(os.path.join(root, f))
        else:
            targets.append(arg)

    all_problems = []
    for path in targets:
        with open(path, "r", encoding="utf-8-sig") as fh:
            src = fh.read()
        all_problems.extend(check(src, path))

    if all_problems:
        for p in all_problems:
            print(p)
        print("\n%d problem(s) across %d file(s)" % (len(all_problems), len(targets)))
        return 1
    print("OK - %d file(s) structurally clean" % len(targets))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
