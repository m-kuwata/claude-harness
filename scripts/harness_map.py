#!/usr/bin/env python3
"""harness_map.py — lock.json とセッション状態から読み取り専用ビジュアライザ (markdown) を生成する。

Usage: harness_map.py <lock.json> <state_dir> > harness-map.md
"""
import glob
import json
import os
import sys
from datetime import datetime


def esc(s):
    """mermaid ノードラベル用エスケープ"""
    return str(s).replace('"', "'")


def workflow_mermaid(name, wf):
    lines = ["```mermaid", "flowchart LR"]
    entry = (wf.get("entry") or {}).get("gates") or []
    gates = wf.get("gates") or []
    perm = wf.get("permissions", "edit")
    prev = "S"
    idx = 0
    for g in entry + gates:
        idx += 1
        nid = f"G{idx}"
        label = "/" + g["skill"]
        badges = []
        if g in entry:
            badges.append("entry")
        if g.get("when"):
            badges.append(f"{g['when']} 変更時")
        if g.get("optional"):
            badges.append("optional")
        if g.get("personas"):
            badges.append("👥 " + "+".join(g["personas"]))
        if g.get("output"):
            badges.append("→ " + g["output"])
        if badges:
            label += "<br/><small>" + " / ".join(badges) + "</small>"
        lines.append(f'    {nid}["{esc(label)}"]')
        lines.append(f"    {prev} --> {nid}")
        prev = nid
    lines.append(f'    DONE(["完了{"（read-only）" if perm == "read-only" else ""}"])')
    lines.append(f"    {prev} --> DONE")
    lines.insert(2, f'    S(["{esc("/flow " + name)}"])')
    lines.append("```")
    return "\n".join(lines)


def main():
    lock_path, state_dir = sys.argv[1], sys.argv[2]
    with open(lock_path) as f:
        lock = json.load(f)
    meta = lock["meta"]
    project = lock["project"]["name"]

    out = []
    out.append(f"# harness マップ — {project}")
    out.append("")
    out.append("> このファイルは `/harness-map` により自動生成される読み取り専用ビュー。手で編集しない。")
    out.append(f"> engine v{meta['engine_version']} / source `{meta['source_hash']}` / 生成 {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    out.append("")

    # ---- ワークフロー ----
    out.append("## ワークフロー")
    for name, wf in (lock.get("workflows") or {}).items():
        default = "（デフォルト）" if wf.get("default") else ""
        perm = wf.get("permissions", "edit")
        out.append("")
        out.append(f"### {name} {default}")
        if wf.get("description"):
            out.append(f"{wf['description']}（permissions: `{perm}`）")
        out.append("")
        out.append(workflow_mermaid(name, wf))

    # ---- ペルソナ ----
    personas = lock.get("personas") or {}
    if personas:
        out.append("")
        out.append("## ペルソナ")
        out.append("")
        out.append("| 名前 | agent | model | context 資料 |")
        out.append("|---|---|---|---|")
        for name, p in personas.items():
            out.append(
                f"| {name} | `{p.get('agent', '')}` | {p.get('model', '(継承)')} | "
                f"{', '.join(f'`{c}`' for c in p.get('context') or []) or '—'} |"
            )

    # ---- 設定サマリ ----
    out.append("")
    out.append("## 設定サマリ")
    out.append("")
    tickets = lock.get("tickets") or {}
    out.append(f"- **チケット**: provider=`{tickets.get('provider', 'none')}`"
               + (f" / ブランチ形式 `{tickets['branch_format']}`" if tickets.get("branch_format") else ""))
    ci = lock.get("ci") or {}
    for rule in ci.get("on_edit") or []:
        out.append(f"- **on_edit**: `{rule.get('run')}`")
    for rule in ci.get("on_commit") or []:
        cov = f"（カバレッジ {rule['coverage_min']}% 必須）" if rule.get("coverage_min") else ""
        out.append(f"- **on_commit**: `{rule.get('run')}`{cov}")
    paths = lock.get("paths") or {}
    if paths:
        out.append(f"- **paths クラス**: {', '.join(f'`{c}`' for c in paths)}")

    # ---- 稼働セッション ----
    out.append("")
    out.append("## 稼働中セッション")
    out.append("")
    states = sorted(glob.glob(os.path.join(state_dir, "*.json")))
    if not states:
        out.append("（なし）")
    else:
        out.append("| セッション | ワークフロー | チケット | ゲート進行 |")
        out.append("|---|---|---|---|")
        for spath in states:
            try:
                with open(spath) as f:
                    st = json.load(f)
            except (json.JSONDecodeError, OSError):
                continue
            gates = st.get("gates") or {}
            done = ", ".join(f"{g}✓" for g, v in gates.items()
                             if v.get("status") in ("passed", "skipped")) or "—"
            pend = (st.get("pending_token") or {}).get("gate")
            prog = done + (f" → **{pend}** (待ち)" if pend else "")
            out.append(f"| `{st.get('session_id', '?')[:16]}` | {st.get('workflow') or '未宣言'} "
                       f"| {st.get('ticket') or '—'} | {prog} |")

    print("\n".join(out))


if __name__ == "__main__":
    main()
