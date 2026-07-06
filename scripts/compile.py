#!/usr/bin/env python3
"""compile.py — harness.yaml(JSON化済み) を検証し harness.lock.json を出力する。

stdin: harness.yaml を JSON 変換したもの
stdout: lock JSON
検証エラー時: stderr にエラー一覧を出し exit 1
"""
import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone

VALID_PERMISSIONS = {"edit", "read-only"}
VALID_PROVIDERS = {"github-issues", "github-projects", "none"}


def expand_braces(pattern):
    """{a,b} を展開してパターンのリストを返す（ネスト対応・簡易版）"""
    m = re.search(r"\{([^{}]*)\}", pattern)
    if not m:
        return [pattern]
    out = []
    for alt in m.group(1).split(","):
        out.extend(expand_braces(pattern[: m.start()] + alt + pattern[m.end():]))
    return out


def glob_to_re(glob):
    """単一 glob を正規表現へ。パスはプロジェクトルート相対で照合される前提"""
    glob = glob.lstrip("/")
    i, out = 0, []
    while i < len(glob):
        c = glob[i]
        if glob[i : i + 3] == "**/":
            out.append(r"(?:.*/)?")
            i += 3
        elif glob[i : i + 2] == "**":
            out.append(r".*")
            i += 2
        elif c == "*":
            out.append(r"[^/]*")
            i += 1
        elif c == "?":
            out.append(r"[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    return "".join(out)


def globs_to_re(globs):
    """glob リスト → 単一のアンカー付き正規表現。空なら None"""
    if not globs:
        return None
    alts = []
    for g in globs:
        for e in expand_braces(g):
            alts.append(glob_to_re(e))
    return "^(?:" + "|".join(alts) + ")$"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--engine-version", required=True)
    args = ap.parse_args()

    try:
        cfg = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        sys.exit(f"harness.yaml の JSON 変換結果が不正です: {e}")

    errors = []

    def err(msg):
        errors.append(msg)

    if not isinstance(cfg, dict):
        sys.exit("harness.yaml のトップレベルはマップである必要があります")

    if cfg.get("version") != 0:
        err("version: 0 が必要です")
    if not cfg.get("project", {}).get("name"):
        err("project.name は必須です")

    # ---- paths ----
    paths = {}
    for cls, spec in (cfg.get("paths") or {}).items():
        inc = globs_to_re((spec or {}).get("include") or [])
        if inc is None:
            err(f"paths.{cls}: include が空です")
            continue
        paths[cls] = {
            "include_re": inc,
            "exclude_re": globs_to_re((spec or {}).get("exclude") or []),
        }

    # ---- tickets ----
    tickets = cfg.get("tickets") or {"provider": "none"}
    if tickets.get("provider") not in VALID_PROVIDERS:
        err(f"tickets.provider は {sorted(VALID_PROVIDERS)} のいずれかです")
    for cls in tickets.get("exempt") or []:
        if cls not in paths:
            err(f"tickets.exempt: 未定義の paths クラス '{cls}'")

    # ---- ci ----
    ci = {"on_edit": [], "on_commit": []}
    for rule in (cfg.get("ci") or {}).get("on_edit") or []:
        r = dict(rule)
        r["paths_re"] = globs_to_re(rule.get("paths") or [])
        if not r.get("run"):
            err("ci.on_edit: run は必須です")
        ci["on_edit"].append(r)
    for rule in (cfg.get("ci") or {}).get("on_commit") or []:
        r = dict(rule)
        r["when_staged_re"] = globs_to_re(rule.get("when_staged") or [])
        if not r.get("run"):
            err("ci.on_commit: run は必須です")
        ci["on_commit"].append(r)

    # ---- guards ----
    guards = {"reuse": []}
    for rule in (cfg.get("guards") or {}).get("reuse") or []:
        r = dict(rule)
        r["on_create_re"] = globs_to_re([rule.get("on_create", "")])
        guards["reuse"].append(r)

    # ---- personas ----
    personas = cfg.get("personas") or {}
    for name, p in personas.items():
        if not (p or {}).get("agent"):
            err(f"personas.{name}: agent は必須です")

    # ---- workflows ----
    workflows = cfg.get("workflows") or {}
    if not workflows:
        err("workflows が空です")
    defaults = [n for n, w in workflows.items() if (w or {}).get("default")]
    if len(defaults) > 1:
        err(f"default: true のワークフローが複数あります: {defaults}")
    for name, w in workflows.items():
        w = w or {}
        perm = w.get("permissions", "edit")
        if perm not in VALID_PERMISSIONS:
            err(f"workflows.{name}.permissions は {sorted(VALID_PERMISSIONS)} のいずれかです")
        w["permissions"] = perm
        gates = w.get("gates") or []
        entry = (w.get("entry") or {}).get("gates") or []
        for g in entry + gates:
            if not g.get("skill"):
                err(f"workflows.{name}: gates[].skill は必須です")
            if g.get("when") and g["when"] not in paths:
                err(f"workflows.{name}.gates[{g.get('skill')}]: 未定義の paths クラス '{g['when']}'")
            if "verify" in g and not isinstance(g["verify"], str):
                err(f"workflows.{name}.gates[{g.get('skill')}]: verify は文字列（シェルコマンド）である必要があります")
            for p in g.get("personas") or []:
                if p not in personas:
                    err(f"workflows.{name}.gates[{g.get('skill')}]: 未定義のペルソナ '{p}'")
        workflows[name] = w

    if errors:
        print("harness.yaml 検証エラー:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    with open(args.source, "rb") as f:
        source_hash = hashlib.sha256(f.read()).hexdigest()[:16]

    lock = {
        "meta": {
            "engine_version": args.engine_version,
            "schema_version": 0,
            "source": args.source,
            "source_hash": source_hash,
            "root": args.root,
            "compiled_at": datetime.now(timezone.utc).isoformat(),
        },
        "project": cfg["project"],
        "setup": cfg.get("setup") or {},
        "paths": paths,
        "tickets": tickets,
        "ci": ci,
        "guards": guards,
        "personas": personas,
        "workflows": workflows,
        "default_workflow": defaults[0] if defaults else None,
    }
    json.dump(lock, sys.stdout, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
