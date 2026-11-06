#!/usr/bin/env python3
"""ask-first-sed.py - read a shell command on stdin and describe every sed statement in it, so Ask First
(lib/ask-first.sh) can run the same sed program on a copy of a settings file and compare the switches before and after.

Output: one JSON object per line, one per sed statement:
  {"opts": [...], "scripts": [...], "files": [...], "inplace": true|false, "redirects": [...], "unclear": "why"|""}
  opts       the options to repeat on the copy (-n, -E, -z, -s, -l N, ...), the in-place option left out
  scripts    the sed programs, in order (from -e/--expression, or the first word when there is none)
  files      the files the statement reads
  inplace    -i or --in-place was given
  redirects  the files its output is redirected to (> or >>)
  unclear    set when the statement cannot be repeated faithfully (a script file, an option this reader does not know)
The words are read the way the shell reads them (quotes, backslashes, comments) by shlex, which never runs anything.
A command shlex cannot read prints one object with only "unclear" set.

With --statements <ERE>: one object per statement instead, {"program": ..., "names": bool, "writes": bool}: the program
it runs, whether a word of it names a settings file (the ERE), and whether it writes one (a redirection into it, or tee).
"""
import json
import re
import shlex
import sys

SEPARATORS = {";", "&", "&&", "|", "||", "(", ")", "\n", ";;", "|&"}
REDIRECTS = {">", ">>", ">|", "&>", "&>>", ">&", "<", "<<", "<<<", "<>", "<&"}
PREFIX_WORDS = {"sudo", "env", "command", "builtin", "exec", "nohup", "time", "nice", "stdbuf", "ionice", "setsid",
                "timeout", "!", "then", "do", "else", "elif", "if", "while", "until"}
FLAG_ONLY = {"-n", "--quiet", "--silent", "-E", "-r", "--regexp-extended", "-s", "--separate", "-z", "--null-data",
             "-u", "--unbuffered", "--posix", "--debug", "--sandbox", "--follow-symlinks", "-b", "--binary"}


def statements(text):
    lexer = shlex.shlex(text, posix=True, punctuation_chars="();<>|&\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    lexer.commenters = "#"
    current = []
    for token in lexer:
        if token in SEPARATORS or (token and set(token) <= set(";&|()\n") and not set(token) & set("<>")):
            if current:
                yield current
            current = []
        else:
            current.append(token)
    if current:
        yield current


def describe(words):
    """Describe one sed statement, or None when the statement does not run sed."""
    i = 0
    while i < len(words) and (words[i] in PREFIX_WORDS or words[i].startswith("-") or ("=" in words[i] and words[i].split("=", 1)[0].isidentifier())):
        if words[i] == "timeout" and i + 1 < len(words):
            i += 1  # its duration
        i += 1
    if i >= len(words) or words[i].rsplit("/", 1)[-1] != "sed":
        return None
    out = {"opts": [], "scripts": [], "files": [], "inplace": False, "redirects": [], "unclear": ""}
    rest = []
    j = i + 1
    while j < len(words):
        w = words[j]
        if w in REDIRECTS:
            if j + 1 < len(words) and w in {">", ">>", ">|", "&>", "&>>"}:
                out["redirects"].append(words[j + 1])
            elif w in {"<", "<>"} and j + 1 < len(words):
                out["files"].append(words[j + 1])
            j += 2
            continue
        if w.isdigit() and j + 1 < len(words) and words[j + 1] in REDIRECTS:
            j += 1  # the file descriptor of the redirection that follows
            continue
        rest.append(w)
        j += 1
    positional = []
    k = 0
    options_done = False
    while k < len(rest):
        w = rest[k]
        k += 1
        if options_done or not w.startswith("-") or w == "-":
            positional.append(w)
            continue
        if w == "--":
            options_done = True
        elif w in FLAG_ONLY:
            out["opts"].append(w)
        elif w == "--in-place" or w.startswith("--in-place="):
            out["inplace"] = True
        elif w in ("--expression", "--line-length", "-l") or w.startswith("--expression=") or w.startswith("--line-length="):
            name, _, value = w.partition("=")
            if not _:
                if k >= len(rest):
                    out["unclear"] = "sed option %s has no value" % w
                    break
                value = rest[k]
                k += 1
            if name == "--expression":
                out["scripts"].append(value)
            else:
                out["opts"] += ["-l", value]
        elif w in ("-f", "--file") or w.startswith("--file="):
            out["unclear"] = "sed reads its program from a file"
            break
        elif w.startswith("--"):
            out["unclear"] = "sed option %s is not known to this check" % w
            break
        else:
            # A group of short options: -ni, -Ei.bak, -ne SCRIPT, -eSCRIPT.
            letters = w[1:]
            p = 0
            while p < len(letters):
                c = letters[p]
                p += 1
                if c == "i":
                    out["inplace"] = True
                    break  # the rest is the backup suffix
                if c in "e" or c in "l":
                    value = letters[p:]
                    if not value:
                        if k >= len(rest):
                            out["unclear"] = "sed option -%s has no value" % c
                            break
                        value = rest[k]
                        k += 1
                    if c == "e":
                        out["scripts"].append(value)
                    else:
                        out["opts"] += ["-l", value]
                    break
                if c == "f":
                    out["unclear"] = "sed reads its program from a file"
                    break
                if "-" + c in FLAG_ONLY:
                    out["opts"].append("-" + c)
                    continue
                out["unclear"] = "sed option -%s is not known to this check" % c
                break
            if out["unclear"]:
                break
    if not out["scripts"] and not out["unclear"]:
        if not positional:
            out["unclear"] = "sed is given no program"
            return out
        out["scripts"].append(positional.pop(0))
    out["files"] += positional
    return out


def program(words):
    """The program a statement runs: the first word after keywords, wrappers, options and assignments; git is named by
    its subcommand (git:add, git:push), a shell given a command string gets "+c"."""
    i = 0
    while i < len(words) and (words[i] in PREFIX_WORDS or words[i].startswith("-") or ("=" in words[i] and words[i].split("=", 1)[0].isidentifier())):
        if words[i] == "timeout" and i + 1 < len(words):
            i += 1
        i += 1
    while i < len(words) and words[i] in REDIRECTS:
        i += 2
    if i >= len(words):
        return ""
    name = words[i].rsplit("/", 1)[-1]
    rest = words[i + 1:]
    if name == "git":
        j = 0
        while j < len(rest):
            if rest[j] in ("-c", "-C"):
                j += 2
                continue
            if rest[j].startswith("-"):
                j += 1
                continue
            return "git:" + rest[j]
        return "git"
    if any(w == "-c" or (w.startswith("-") and not w.startswith("--") and w.endswith("c")) for w in rest):
        return name + "+c"
    return name


def statement_lines(text, target_re):
    """One JSON object per statement: the program it runs, whether it names a settings file (target_re), and whether it
    writes one through an output redirection or tee."""
    pattern = re.compile(target_re)
    for words in statements(text):
        names = any(pattern.search(w) for w in words)
        writes = False
        for k, w in enumerate(words):
            if w in (">", ">>", ">|", "&>", "&>>") and k + 1 < len(words) and pattern.search(words[k + 1]):
                writes = True
        prog = program(words)
        if prog == "tee" and names:
            writes = True
        print(json.dumps({"program": prog, "names": names, "writes": writes}))


def main():
    text = sys.stdin.read()
    if len(sys.argv) > 2 and sys.argv[1] == "--statements":
        try:
            statement_lines(text, sys.argv[2])
        except (ValueError, re.error) as error:
            print(json.dumps({"unclear": "the command cannot be read (%s)" % error}))
        return
    try:
        for words in statements(text):
            described = describe(words)
            if described is not None:
                print(json.dumps(described))
    except ValueError as error:  # an unbalanced quote: the command cannot be read for certain
        print(json.dumps({"unclear": "the command cannot be read (%s)" % error}))


if __name__ == "__main__":
    main()
