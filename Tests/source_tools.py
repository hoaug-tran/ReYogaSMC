"""Locate production definitions without depending on indentation or line breaks."""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
_TOKEN = re.compile(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|/\*[\s\S]*?\*/|//[^\n]*|[{}]')


def read_sources(*patterns):
    paths = sorted({path for pattern in patterns for path in ROOT.glob(pattern) if path.is_file()})
    if not paths:
        raise ValueError(f'No source files matched {patterns}')
    return '\n'.join(path.read_text(encoding='utf-8') for path in paths)


def app_sources():
    return read_sources('ReYogaSMCApp/**/*.swift')


def kernel_sources(owner):
    return read_sources(f'ReYogaSMC/**/{owner}*.cpp')


def function(source, signature):
    pattern = r'\s+'.join(re.escape(word) for word in signature.split())
    match = re.search(pattern, source)
    if match is None:
        raise ValueError(f'Function signature not found: {signature}')
    depth = 0
    for token in _TOKEN.finditer(source, match.end()):
        if token.group() == '{':
            depth += 1
        elif token.group() == '}':
            depth -= 1
            if depth == 0:
                return source[match.start():token.end()]
    raise ValueError(f'Function body not closed: {signature}')
