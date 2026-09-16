#!/usr/bin/env python3
"""Project Conventional Commit checks; no network, writes, or Git mutations."""
from pathlib import Path
import argparse
import json
import re
import subprocess
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
POLICY=json.loads((ROOT/'planning/git-policy.json').read_text(encoding='utf-8'))['message']
HEADER=re.compile(r'(?P<type>[a-z]+)\((?P<scope>'+POLICY['scope_pattern']+r')\)(?P<bang>!)?: (?P<subject>\S.*)\Z')
BREAKING=re.compile(r'^BREAKING(?: CHANGE|-CHANGE): \S.*$',re.MULTILINE)

def errors(message, title_only=False):
    lines=message.splitlines()
    if not lines:return ['empty commit message']
    title=lines[0]
    issues=[]
    if len(title)>POLICY['header_max_characters']:issues.append('header exceeds 72 Unicode characters')
    if any(ord(c)<32 or ord(c)==127 for c in title):issues.append('header contains control characters')
    match=HEADER.fullmatch(title)
    if not match:issues.append('expected type(scope): subject; lowercase type/scope and one space after colon')
    else:
        if match['type'] not in POLICY['types']:issues.append('type is not in project allowlist')
        if match['subject']!=match['subject'].strip():issues.append('subject has trailing whitespace')
    if title_only:
        if any(line.strip() for line in lines[1:]):issues.append('PR title must be one line')
        return issues
    if len(lines)>1 and lines[1].strip():issues.append('body/footer must be separated from title by a blank line')
    footers=list(BREAKING.finditer(message))
    has_footer=False
    for footer in footers:
        # A footer paragraph starts after a blank line; support consecutive trailers.
        before=message[:footer.start()].splitlines()
        if before and (not before[-1].strip() or re.match(r'^[A-Za-z][A-Za-z-]*: \S',before[-1])):
            has_footer=True
    bang=bool(match and match['bang'])
    if bang and not has_footer:issues.append('breaking header requires a non-empty BREAKING CHANGE footer')
    if has_footer and not bang:issues.append('project policy requires ! for a breaking footer')
    return issues

class MessageTests(unittest.TestCase):
    def test_valid(self):
        for m in ['feat(issues): 新增任务看板与筛选','fix(serial): preserve raw bytes','docs(git-policy): 明确提交规则\n\nRefs: EMB-42','revert(devices): 撤销采集策略','feat(api)!: 更新绑定契约\n\nBREAKING CHANGE: 客户端迁移binding字段','fix(api)!: 更正返回结构\n\nBREAKING-CHANGE: 迁移旧客户端']:
            with self.subTest(message=m):self.assertEqual(errors(m),[])
    def test_invalid_headers(self):
        for m in ['', 'feat: 无scope','Feat(ui): 大写type','feat(UI): 大写scope','feet(ui): 错误type','feat(ui):缺空格','feat(ui):  多余空格','feat(ui): ','feat(ui): 末尾空格 ','feat(ui): 制表\t字符','Merge branch main','fixup! feat(ui): 临时提交','feat(ui): '+'长'*64]:
            with self.subTest(message=m):self.assertTrue(errors(m))
    def test_exact_length(self):
        title='feat(ui): '+'长'*62
        self.assertEqual(len(title),72)
        self.assertEqual(errors(title),[])
    def test_body_separator(self):
        self.assertTrue(errors('fix(api): fix behavior\nbody without separator'))
    def test_breaking_contract(self):
        for m in ['feat(api)!: 修改接口','feat(api)!: 修改接口\n\nBREAKING CHANGE: ', 'feat(api): 修改接口\n\nBREAKING CHANGE: 不兼容','feat(api)!: 修改接口\n\n# BREAKING CHANGE: 不是正文footer']:
            with self.subTest(message=m):self.assertTrue(errors(m))
    def test_title_only(self):
        self.assertEqual(errors('feat(api)!: 修改接口',title_only=True),[])
        self.assertTrue(errors('feat(api): 修改接口\nextra',title_only=True))
    def test_crlf(self):
        self.assertEqual(errors('feat(api)!: change binding\r\n\r\nBREAKING CHANGE: migrate clients\r\n'),[])

def run_git(repo,*args):
    result=subprocess.run(['git','-C',str(repo),*args],capture_output=True,text=True,encoding='utf-8',errors='replace')
    if result.returncode:raise ValueError('Git could not resolve the requested repository/commit range')
    return result.stdout

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--file',type=Path)
    mode.add_argument('--title-file',type=Path)
    mode.add_argument('--range',dest='commit_range')
    mode.add_argument('--self-test',action='store_true')
    parser.add_argument('--repo',type=Path,default=Path.cwd())
    args=parser.parse_args()
    if args.self_test:
        result=unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(MessageTests))
        return 0 if result.wasSuccessful() else 1
    try:
        if args.commit_range:
            if not re.fullmatch(r'[0-9a-fA-F]{7,64}\.\.[0-9a-fA-F]{7,64}',args.commit_range):
                raise ValueError('--range must be pinned BASE_SHA..HEAD_SHA, not untrusted flags or symbolic refs')
            for revision in args.commit_range.split('..'):
                run_git(args.repo,'rev-parse','--verify',revision+'^{commit}')
            commits=run_git(args.repo,'rev-list','--reverse','--no-merges',args.commit_range).splitlines()
            failures=[]
            for commit in commits:
                found=errors(run_git(args.repo,'show','-s','--format=%B',commit))
                if found:failures.append((commit,found))
            for commit,found in failures:print(commit[:12]+': '+'; '.join(found),file=sys.stderr)
            print(f'Checked {len(commits)} new non-merge commits; failures: {len(failures)}')
            return 1 if failures else 0
        path=args.file or args.title_file
        message=path.read_text(encoding='utf-8-sig')
        found=errors(message,title_only=bool(args.title_file))
        for problem in found:print(problem,file=sys.stderr)
        if not found:print('Commit/PR title format passed')
        return 1 if found else 0
    except (OSError,ValueError) as exc:
        print(str(exc),file=sys.stderr)
        return 2

if __name__=='__main__':sys.exit(main())
