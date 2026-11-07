#!/usr/bin/env python3
"""扫描 L10n.t("中文", "English") 的第一个参数：出现「中文字符 + 半角标点」就报错。

只检查字符串字面量的顶层文本（跳过 \\( … ) 插值内部），半角标点紧跟在中文字符后面才算违规，
这样 "http://"、"12:30"、"(Esc)" 这类不会误报。"""
import re, sys, pathlib

CJK = re.compile(r'[一-鿿㐀-䶿]')
PUNCT = ',.:;!?'

def first_literal(src, i):
    """src[i] 是开头的引号；返回 (顶层文本片段列表, 结束位置)"""
    assert src[i] == '"'
    i += 1
    depth = 0
    top = []
    buf = ''
    while i < len(src):
        c = src[i]
        if depth == 0:
            if c == '\\' and i + 1 < len(src):
                if src[i + 1] == '(':
                    top.append(buf); buf = ''
                    depth = 1; i += 2; continue
                buf += src[i:i + 2]; i += 2; continue
            if c == '"':
                top.append(buf)
                return top, i + 1
            buf += c
        else:
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
            elif c == '"':
                # 插值里的嵌套字符串：跳到配对引号
                j = i + 1
                while j < len(src) and src[j] != '"':
                    j += 2 if src[j] == '\\' else 1
                i = j
        i += 1
    return top, i

def main(root):
    bad = 0
    for path in sorted(pathlib.Path(root).rglob('*.swift')):
        src = path.read_text(encoding='utf-8')
        for m in re.finditer(r'L10n\.t\(\s*"', src):
            start = m.end() - 1
            if src[start - 1:start + 3] == '""""':
                continue
            parts, _ = first_literal(src, start)
            for part in parts:
                for k in range(1, len(part)):
                    if part[k] in PUNCT and CJK.match(part[k - 1]):
                        line = src.count('\n', 0, start) + 1
                        print(f'  ✗ {path}:{line} 「{part[max(0, k - 6):k + 4]}」中文后用了半角「{part[k]}」')
                        bad += 1
                        break
    if bad == 0:
        print('  ✓ L10n.t 中文文案没有半角标点')
    return bad

if __name__ == '__main__':
    sys.exit(1 if main(sys.argv[1] if len(sys.argv) > 1 else 'Sources') else 0)
