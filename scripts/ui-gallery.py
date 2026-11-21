#!/usr/bin/env python3
"""uTerm 界面画廊：把 UICatalogSnapshotTests 落的 PNG + manifest.json 拼成一个 HTML 页。

用法：
  scripts/ui-gallery.py build  <出图目录> [--out index.html] [--title 标题] [--artifact <发布包目录>]
  scripts/ui-gallery.py diff   <改动前目录> <改动后目录> [--out diff.html] [--minor 0.002]

出图：`make gallery`（UICatalogSnapshotTests 浅 / 深各一张 + manifest.json，再调本脚本 build）。
`--artifact` 另出一份 claude.ai Artifact 发布包（片段 HTML + 压成 JPEG 的图，单次发布 ≤255 个文件，
分两批发到同一个 URL）。

build：左侧层级树、右侧缩略图网格、点开大图、浅 / 深并排、按 ID 搜索；每张标 ID 与源码位置
（行号此刻现查：manifest 只记文件 + 类型名，免得改代码后行号失效）。
diff：两次出图逐张比对像素字节，只列「变了 / 新增 / 删掉」的界面，大图里改动前后并排 + 滑块。

图片不内嵌：HTML 用相对路径引用同目录下的 PNG（diff 页引用两个目录，会把图拷进 diff 目录）。
只用标准库。
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def resolve_line(source: str, symbol: str) -> int | None:
    path = REPO / source
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    lines = text.splitlines()
    decl = re.compile(r"\b(struct|class|enum|func|var|let|case)\s+" + re.escape(symbol) + r"\b")
    for i, line in enumerate(lines, 1):
        if decl.search(line):
            return i
    word = re.compile(r"\b" + re.escape(symbol) + r"\b")
    for i, line in enumerate(lines, 1):
        if word.search(line):
            return i
    return None


def load_manifest(directory: Path) -> dict:
    with open(directory / "manifest.json", encoding="utf-8") as f:
        data = json.load(f)
    for e in data["entries"]:
        e["line"] = resolve_line(e["source"], e["symbol"])
    return data


def digest(path: Path) -> str | None:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


DOC_OPEN = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
"""

PAGE = r"""<title>__TITLE__</title>
<meta name="claude:viewport-fit-sides" content="cover">
<style>
:root {
  --bg: #f5f5f4; --panel: #ffffff; --panel2: #fafaf9; --line: #e7e5e4; --text: #1c1917;
  --text2: #57534e; --text3: #a8a29e; --accent: #2563eb; --accent-tint: #dbeafe;
  --warn: #b45309; --warn-tint: #fef3c7; --bad: #b91c1c; --bad-tint: #fee2e2; --ok: #15803d; --ok-tint: #dcfce7;
  --shadow: 0 1px 2px rgba(0,0,0,.06), 0 4px 16px rgba(0,0,0,.05);
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #111110; --panel: #1c1b1a; --panel2: #232220; --line: #2e2c2a; --text: #f5f5f4;
    --text2: #c4c0bc; --text3: #78716c; --accent: #60a5fa; --accent-tint: #1e3a5f;
    --warn: #fbbf24; --warn-tint: #3d2f0b; --bad: #f87171; --bad-tint: #3f1515; --ok: #4ade80; --ok-tint: #12301c;
    --shadow: 0 1px 2px rgba(0,0,0,.4); color-scheme: dark;
  }
}
:root[data-theme="dark"] {
  --bg: #111110; --panel: #1c1b1a; --panel2: #232220; --line: #2e2c2a; --text: #f5f5f4;
  --text2: #c4c0bc; --text3: #78716c; --accent: #60a5fa; --accent-tint: #1e3a5f;
  --warn: #fbbf24; --warn-tint: #3d2f0b; --bad: #f87171; --bad-tint: #3f1515; --ok: #4ade80; --ok-tint: #12301c;
  --shadow: 0 1px 2px rgba(0,0,0,.4); color-scheme: dark;
}
* { box-sizing: border-box; }
html, body { margin: 0; height: 100%; }
.cmt { display: none; border: 0; border-radius: 6px; background: var(--accent-tint); color: var(--accent); font: inherit; font-size: 11.5px; font-weight: 600; padding: 2px 8px; cursor: pointer; margin-left: 6px; }
.can-comment .cmt { display: inline-block; }
.cmt:focus-visible, .chip:focus-visible, .seg button:focus-visible, .node:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
.cmt-hint { color: var(--text3); font-size: 11px; }
body { background: var(--bg); color: var(--text); font: 13px/1.45 -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", sans-serif; }
.app { display: grid; grid-template-columns: 280px 1fr; height: 100%; }
aside { border-right: 1px solid var(--line); background: var(--panel); overflow: auto; padding-block: 14px 40px; padding-left: max(10px, env(safe-area-inset-left, 0px)); padding-right: 10px; }
main { overflow: auto; padding-block: 18px 60px; padding-left: 22px; padding-right: max(22px, env(safe-area-inset-right, 0px)); min-width: 0; }
h1 { font-size: 15px; margin: 2px 6px 4px; }
.sub { color: var(--text3); font-size: 11.5px; margin: 0 6px 12px; }
.search { width: 100%; padding: 7px 10px; border-radius: 8px; border: 1px solid var(--line); background: var(--panel2); color: var(--text); font: inherit; margin-bottom: 10px; }
.search:focus { outline: 2px solid var(--accent); outline-offset: -1px; }
.chips { display: flex; flex-wrap: wrap; gap: 5px; margin: 0 2px 12px; }
.chip { border: 0; border-radius: 999px; padding: 3px 9px; background: var(--panel2); color: var(--text2); font: inherit; font-size: 11.5px; cursor: pointer; }
.chip.on { background: var(--accent-tint); color: var(--accent); font-weight: 600; }
.tree, .tree ul { list-style: none; margin: 0; padding: 0; }
.tree ul { padding-left: 12px; }
.node { display: flex; align-items: center; gap: 6px; padding: 3px 6px; border-radius: 6px; cursor: pointer; color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.node:hover { background: var(--panel2); }
.node.on { background: var(--accent-tint); color: var(--accent); }
.node .n { margin-left: auto; color: var(--text3); font-size: 11px; font-variant-numeric: tabular-nums; }
.node .caret { width: 10px; color: var(--text3); font-size: 9px; }
.toolbar { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; flex-wrap: wrap; }
.toolbar .crumb { font-weight: 600; font-size: 14px; }
.toolbar .count { color: var(--text3); }
.seg { display: inline-flex; background: var(--panel); border-radius: 8px; padding: 2px; box-shadow: var(--shadow); margin-left: auto; }
.seg button { border: 0; background: none; color: var(--text2); padding: 4px 10px; border-radius: 6px; font: inherit; cursor: pointer; }
.seg button.on { background: var(--accent-tint); color: var(--accent); font-weight: 600; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(var(--card, 440px), 1fr)); gap: 16px; }
.card { background: var(--panel); border-radius: 12px; box-shadow: var(--shadow); overflow: hidden; display: flex; flex-direction: column; }
.thumbs { display: grid; grid-template-columns: 1fr 1fr; gap: 1px; background: var(--line); cursor: zoom-in; }
.thumbs.single { grid-template-columns: 1fr; }
.thumbs img { width: 100%; display: block; background: var(--panel2); aspect-ratio: var(--ar); object-fit: contain; }
.meta { padding: 10px 12px 12px; display: flex; flex-direction: column; gap: 4px; }
.id { font-weight: 600; word-break: break-all; }
.id button { border: 0; background: none; color: var(--text3); cursor: pointer; font: inherit; font-size: 11px; padding: 0 4px; }
.id button:hover { color: var(--accent); }
.src { font: 11.5px ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--text2); word-break: break-all; }
.tags { display: flex; gap: 6px; flex-wrap: wrap; font-size: 11px; color: var(--text3); }
.tag { background: var(--panel2); border-radius: 4px; padding: 1px 6px; }
.tag.k-window { color: var(--accent); } .tag.err, .tag.removed { background: var(--bad-tint); color: var(--bad); }
.tag.changed { background: var(--warn-tint); color: var(--warn); } .tag.added { background: var(--ok-tint); color: var(--ok); }
.note { color: var(--text2); font-size: 12px; }
.empty { color: var(--text3); padding: 40px; text-align: center; }
.lb { position: fixed; inset: 0; background: rgba(0,0,0,.82); display: none; flex-direction: column; z-index: 10; }
.lb.on { display: flex; }
.lb header { display: flex; align-items: center; gap: 12px; padding: 10px 16px; color: #eee; }
.lb header .id { font-size: 14px; }
.lb header .src { color: #bbb; }
.lb .seg { margin-left: auto; background: #2a2a2a; box-shadow: none; }
.lb .seg button { color: #ccc; } .lb .seg button.on { background: #3b4a63; color: #fff; }
.lb .x { border: 0; background: #333; color: #eee; border-radius: 6px; padding: 4px 10px; cursor: pointer; font: inherit; }
.lb .stage { flex: 1; overflow: auto; display: flex; gap: 12px; padding: 0 16px 16px; align-items: flex-start; justify-content: center; }
.lb .stage figure { margin: 0; flex: 1; max-width: 100%; }
.lb .stage figcaption { color: #aaa; font-size: 11.5px; margin-bottom: 4px; }
.lb .stage img { max-width: 100%; display: block; border-radius: 6px; }
.lb .stage.zoom img { max-width: none; width: auto; }
.slider { position: relative; display: inline-block; max-width: 100%; }
.slider img { display: block; }
.slider .top { position: absolute; inset: 0; overflow: hidden; }
.slider .top img { max-width: none; }
.slider input { width: 100%; }
.hint { color: #999; font-size: 11px; padding: 0 16px 8px; }
.pic { position: relative; }
.bbox { position: absolute; outline: 2px solid #f43f5e; outline-offset: 2px; border-radius: 3px; pointer-events: none; }
@media (max-width: 760px) {
  .app { grid-template-columns: 1fr; height: auto; }
  aside { max-height: 45vh; border-right: 0; border-bottom: 1px solid var(--line); }
  main { padding-block: 14px 40px; padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px)); }
  aside { padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px)); }
  .grid { grid-template-columns: 1fr; }
  .seg { margin-left: 0; }
}
</style>
__BODY_OPEN__<div class="app">
  <aside>
    <h1>__TITLE__</h1>
    <div class="sub" id="sub"></div>
    <input class="search" id="q" placeholder="按 ID / 源码搜索（/ 聚焦）" autocomplete="off">
    <div class="chips" id="kinds"></div>
    <ul class="tree" id="tree"></ul>
  </aside>
  <main>
    <div class="toolbar">
      <span class="crumb" id="crumb">全部</span><span class="count" id="count"></span>
      <div class="seg" id="mode"></div>
      <div class="seg" id="sizeSeg"></div>
    </div>
    <div class="grid" id="grid"></div>
  </main>
</div>
<div class="lb" id="lb">
  <header>
    <span class="id" id="lbId" data-comment-target></span><button class="cmt" id="lbCmt">评论</button><span class="src" id="lbSrc"></span>
    <div class="seg" id="lbMode"></div>
    <button class="x" id="lbZoom">1:1</button>
    <button class="x" id="lbClose">关闭 Esc</button>
  </header>
  <div class="hint">← / → 切换上一张 / 下一张</div>
  <div class="stage" id="lbStage"></div>
</div>
<script>
const DATA = __DATA__;
const KIND_LABEL = {window: "整窗", sheet: "弹窗", popover: "Popover", panel: "面板", component: "组件", alert: "警告框"};
const STATUS_LABEL = {changed: "有变化", added: "新增", removed: "已删除", minor: "微小变化"};
const kindOf = e => isDiff ? (e.minor ? "minor" : e.status) : e.kind;
const isDiff = DATA.mode === "diff";
const state = { q: "", prefix: "", kinds: new Set(), showMinor: false, mode: isDiff ? "after" : "both", lbMode: isDiff ? "pair" : "both", idx: -1, list: [], zoom: false, card: 440 };
const store = (() => { try { return window.localStorage; } catch (e) { return null; } })();
try { const s = JSON.parse(store?.getItem("ui-gallery") || "{}"); Object.assign(state, {mode: s.mode || state.mode, card: s.card || state.card}); } catch (e) {}
const save = () => { try { store?.setItem("ui-gallery", JSON.stringify({mode: state.mode, card: state.card})); } catch (e) {} };
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c]));
const srcOf = e => e.source + (e.line ? ":" + e.line : "");

document.getElementById("sub").textContent = isDiff
  ? `改动前 ${DATA.before} → 改动后 ${DATA.after} · ${DATA.entries.length} 处变化（共比对 ${DATA.total} 条）`
  : `${DATA.entries.length} 个界面 / 状态 · ${DATA.generatedAt || ""}`;

function buildTree() {
  const root = {children: new Map(), count: 0};
  for (const e of DATA.entries) {
    let n = root; n.count++;
    const parts = e.path.slice(0, -1);
    let acc = "";
    for (const p of parts) {
      acc = acc ? acc + "/" + p : p;
      if (!n.children.has(p)) n.children.set(p, {name: p, prefix: acc, children: new Map(), count: 0});
      n = n.children.get(p); n.count++;
    }
  }
  const ul = document.getElementById("tree");
  const render = (node, depth) => {
    let h = "";
    for (const c of node.children.values()) {
      const kids = c.children.size ? `<ul data-p="${esc(c.prefix)}" ${depth > 0 ? "hidden" : ""}>${render(c, depth + 1)}</ul>` : "";
      h += `<li><div class="node" data-prefix="${esc(c.prefix)}"><span class="caret">${c.children.size ? "▸" : ""}</span>${esc(c.name)}<span class="n">${c.count}</span></div>${kids}</li>`;
    }
    return h;
  };
  ul.innerHTML = `<li><div class="node on" data-prefix=""><span class="caret"></span>全部<span class="n">${root.count}</span></div></li>` + render(root, 0);
  ul.addEventListener("click", ev => {
    const node = ev.target.closest(".node"); if (!node) return;
    state.prefix = node.dataset.prefix;
    ul.querySelectorAll(".node").forEach(n => n.classList.toggle("on", n === node));
    const sub = node.parentElement.querySelector(":scope > ul");
    if (sub) { sub.hidden = !sub.hidden; node.querySelector(".caret").textContent = sub.hidden ? "▸" : "▾"; }
    draw();
  });
}

function buildKinds() {
  const kinds = [...new Set(DATA.entries.map(kindOf))];
  const el = document.getElementById("kinds");
  el.innerHTML = kinds.map(k => `<button class="chip" data-k="${k}">${isDiff ? STATUS_LABEL[k] : (KIND_LABEL[k] || k)} ${DATA.entries.filter(e => kindOf(e) === k).length}</button>`).join("")
    + (isDiff ? "" : `<button class="chip" data-k="__err">出错 ${DATA.entries.filter(e => e.error).length}</button>`);
  el.addEventListener("click", ev => {
    const b = ev.target.closest(".chip"); if (!b) return;
    const k = b.dataset.k;
    if (k === "minor") state.showMinor = !state.showMinor;
    else state.kinds.has(k) ? state.kinds.delete(k) : state.kinds.add(k);
    b.classList.toggle("on"); draw();
  });
}

function seg(el, options, get, set) {
  el.innerHTML = options.map(([v, l]) => `<button data-v="${v}">${l}</button>`).join("");
  const sync = () => el.querySelectorAll("button").forEach(b => b.classList.toggle("on", b.dataset.v === String(get())));
  el.addEventListener("click", ev => { const b = ev.target.closest("button"); if (!b) return; set(b.dataset.v); sync(); });
  sync();
}

function filtered() {
  const q = state.q.trim().toLowerCase();
  return DATA.entries.filter(e => {
    if (state.prefix && !(e.id === state.prefix || e.id.startsWith(state.prefix + "/"))) return false;
    if (isDiff && e.minor && !state.showMinor) return false;
    if ([...state.kinds].some(k => k !== "minor")) {
      const k = kindOf(e);
      if (!(state.kinds.has(k) || (state.kinds.has("__err") && e.error))) return false;
    }
    if (q && !(e.id.toLowerCase().includes(q) || e.source.toLowerCase().includes(q) || (e.symbol || "").toLowerCase().includes(q) || (e.note || "").toLowerCase().includes(q))) return false;
    return true;
  });
}

function imgsFor(e, mode) {
  if (isDiff) {
    const pick = t => ({before: e.before?.[t], after: e.after?.[t]});
    if (mode === "before") return [["改动前 · 浅", e.before?.light], ["改动前 · 深", e.before?.dark]];
    if (mode === "after") return [["改动后 · 浅", e.after?.light], ["改动后 · 深", e.after?.dark]];
    return [["改动前 · 浅", e.before?.light], ["改动后 · 浅", e.after?.light]];
  }
  if (mode === "light") return [["浅色", e.images.light]];
  if (mode === "dark") return [["深色", e.images.dark]];
  return [["浅色", e.images.light], ["深色", e.images.dark]];
}

function draw() {
  state.list = filtered();
  document.getElementById("crumb").textContent = state.prefix || "全部";
  document.getElementById("count").textContent = `${state.list.length} 条`;
  document.documentElement.style.setProperty("--card", state.card + "px");
  const grid = document.getElementById("grid");
  if (!state.list.length) { grid.innerHTML = `<div class="empty">没有匹配的界面</div>`; return; }
  grid.innerHTML = state.list.map((e, i) => {
    const imgs = imgsFor(e, state.mode).filter(x => x[1]);
    const ar = `${e.width} / ${e.height}`;
    const thumbs = imgs.length ? `<div class="thumbs ${imgs.length === 1 ? "single" : ""}" data-i="${i}" style="--ar:${ar}">${imgs.map(([l, f]) => `<img loading="lazy" src="${esc(f)}" alt="${esc(e.id)} ${l}" title="${l}">`).join("")}</div>` : "";
    const pct = e.ratio != null ? ` ${(e.ratio * 100).toFixed(e.ratio < 0.01 ? 2 : 1)}%` : "";
    const status = isDiff ? `<span class="tag ${e.minor ? "changed" : e.status}">${STATUS_LABEL[kindOf(e)]}${pct}</span>` : `<span class="tag k-${e.kind}">${KIND_LABEL[e.kind] || e.kind}</span>`;
    return `<div class="card" data-comment-target data-id="${esc(e.id)}">${thumbs}<div class="meta">
      <div class="id"><span class="idt">${esc(e.id)}</span><button data-copy="${esc(e.id)}" title="复制 ID">复制</button><button class="cmt" data-cmt="1" title="在这张图上留评论（自动引用 ID）">评论</button></div>
      <div class="src">${esc(srcOf(e))} · ${esc(e.symbol)}</div>
      <div class="tags">${status}<span class="tag">${e.width}×${e.height}</span>${e.error ? `<span class="tag err">${esc(e.error)}</span>` : ""}</div>
      ${e.note ? `<div class="note">${esc(e.note)}</div>` : ""}
    </div></div>`;
  }).join("");
}

let commentsApi = null;
(async () => {
  try { commentsApi = await window.claude?.use?.("comments"); } catch (e) { commentsApi = null; }
  if (commentsApi?.openComposer) document.documentElement.classList.add("can-comment");
})();
async function comment(btn, idEl) {
  if (!commentsApi) return;
  const range = document.createRange(); range.selectNodeContents(idEl);
  try {
    const r = await commentsApi.openComposer({range});
    if (r && r.opened === false) { btn.textContent = "先点一下页面"; setTimeout(() => btn.textContent = "评论", 1600); }
  } catch (e) {
    btn.textContent = e?.code === "forbidden" ? "此处不能评论" : "没打开，再试";
    setTimeout(() => btn.textContent = "评论", 1800);
  }
}
document.getElementById("grid").addEventListener("click", ev => {
  const m = ev.target.closest("[data-cmt]");
  if (m) { comment(m, m.closest(".id").querySelector(".idt")); return; }
  const c = ev.target.closest("[data-copy]");
  if (c) {
    const done = t => { c.textContent = t; setTimeout(() => c.textContent = "复制", 1200); };
    const fallback = () => { const r = document.createRange(); r.selectNodeContents(c.previousElementSibling); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r); done("已选中"); };
    try { navigator.clipboard.writeText(c.dataset.copy).then(() => done("已复制"), fallback); } catch (e) { fallback(); }
    return;
  }
  const t = ev.target.closest(".thumbs"); if (t) openLB(+t.dataset.i);
});

function openLB(i) {
  state.idx = i; const e = state.list[i]; if (!e) return;
  document.getElementById("lbId").textContent = e.id;
  document.getElementById("lbSrc").textContent = srcOf(e) + " · " + e.symbol;
  const stage = document.getElementById("lbStage");
  stage.classList.toggle("zoom", state.zoom);
  if (isDiff && state.lbMode === "slider" && e.before?.light && e.after?.light) {
    stage.innerHTML = `<div><div class="slider" id="sl"><img src="${esc(e.after.light)}"><div class="top" id="slTop" style="width:50%"><img src="${esc(e.before.light)}"></div></div><input type="range" min="0" max="100" value="50" id="slR"><div class="hint">左 = 改动前，右 = 改动后（浅色）</div></div>`;
    const top = document.getElementById("slTop"), r = document.getElementById("slR"), base = document.querySelector("#sl > img");
    const fit = () => { top.querySelector("img").style.width = base.getBoundingClientRect().width + "px"; };
    base.onload = fit; fit(); r.oninput = () => top.style.width = r.value + "%";
  } else {
    let pairs;
    if (isDiff) pairs = state.lbMode === "pair"
      ? [["改动前 · 浅", e.before?.light], ["改动后 · 浅", e.after?.light], ["改动前 · 深", e.before?.dark], ["改动后 · 深", e.after?.dark]]
      : imgsFor(e, state.lbMode);
    else pairs = imgsFor(e, state.lbMode);
    pairs = pairs.filter(p => p[1]);
    const cols = isDiff && state.lbMode === "pair" ? 2 : pairs.length;
    stage.style.display = "grid"; stage.style.gridTemplateColumns = `repeat(${cols}, minmax(0, 1fr))`;
    stage.innerHTML = pairs.map(([l, f]) => {
      const theme = l.includes("深") ? "dark" : "light";
      const box = isDiff && l.startsWith("改动后") && e.bbox?.[theme] ? ` data-bbox="${e.bbox[theme].join(",")}"` : "";
      return `<figure><figcaption>${l}</figcaption><div class="pic"${box}><img src="${esc(f)}"></div></figure>`;
    }).join("");
    stage.querySelectorAll(".pic[data-bbox]").forEach(pic => {
      const img = pic.querySelector("img");
      const place = () => {
        const [x, y, w, h] = pic.dataset.bbox.split(",").map(Number);
        const W = img.naturalWidth, H = img.naturalHeight; if (!W) return;
        const d = document.createElement("div"); d.className = "bbox";
        Object.assign(d.style, {left: x / W * 100 + "%", top: y / H * 100 + "%", width: w / W * 100 + "%", height: h / H * 100 + "%"});
        pic.appendChild(d);
      };
      img.complete ? place() : img.addEventListener("load", place);
    });
  }
  document.getElementById("lb").classList.add("on");
}
const closeLB = () => { document.getElementById("lb").classList.remove("on"); state.idx = -1; };
document.getElementById("lbClose").onclick = closeLB;
document.getElementById("lbCmt").onclick = ev => comment(ev.currentTarget, document.getElementById("lbId"));
document.getElementById("lbZoom").onclick = () => { state.zoom = !state.zoom; openLB(state.idx); };
document.getElementById("lb").addEventListener("click", ev => { if (ev.target.id === "lb" || ev.target.id === "lbStage") closeLB(); });
document.addEventListener("keydown", ev => {
  if (ev.key === "/" && document.activeElement.id !== "q") { ev.preventDefault(); document.getElementById("q").focus(); }
  if (state.idx < 0) return;
  if (ev.key === "Escape") closeLB();
  if (ev.key === "ArrowRight") openLB(Math.min(state.list.length - 1, state.idx + 1));
  if (ev.key === "ArrowLeft") openLB(Math.max(0, state.idx - 1));
});
document.getElementById("q").addEventListener("input", ev => { state.q = ev.target.value; draw(); });

seg(document.getElementById("mode"), isDiff ? [["before", "改动前"], ["after", "改动后"], ["pair", "前后对照"]] : [["both", "浅+深"], ["light", "浅色"], ["dark", "深色"]],
    () => state.mode, v => { state.mode = v; save(); draw(); });
seg(document.getElementById("sizeSeg"), [["320", "小"], ["440", "中"], ["640", "大"]], () => state.card, v => { state.card = +v; save(); draw(); });
seg(document.getElementById("lbMode"), isDiff ? [["pair", "前后对照"], ["slider", "滑块"]] : [["both", "浅+深"], ["light", "浅色"], ["dark", "深色"]],
    () => state.lbMode, v => { state.lbMode = v; if (state.idx >= 0) openLB(state.idx); });
buildTree(); buildKinds(); draw();
// 带 #ID 打开：直接定位那张大图（评论里贴链接用）。
if (location.hash.length > 1) {
  const id = decodeURIComponent(location.hash.slice(1));
  const i = state.list.findIndex(e => e.id === id); if (i >= 0) openLB(i);
}
</script>
__BODY_CLOSE__"""


def render_page(data: dict, title: str, artifact: bool = False) -> str:
    """artifact=True 出 claude.ai Artifact 要的片段（发布时套壳），否则出完整文档。"""
    payload = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    page = PAGE.replace("__TITLE__", html.escape(title)).replace("__DATA__", payload)
    if artifact:
        return page.replace("__BODY_OPEN__", "").replace("__BODY_CLOSE__", "")
    return DOC_OPEN + page.replace("__BODY_OPEN__", "</head>\n<body>\n").replace("__BODY_CLOSE__", "</body>\n</html>\n")


def cmd_build(args: argparse.Namespace) -> int:
    src = Path(args.dir).resolve()
    data = load_manifest(src)
    data["mode"] = "gallery"
    out = Path(args.out).resolve() if args.out else src / "index.html"
    if out.parent != src:
        # HTML 引用的是同目录下的相对文件名；放到别处时把图一起拷过去。
        out.parent.mkdir(parents=True, exist_ok=True)
        for e in data["entries"]:
            for f in e["images"].values():
                shutil.copy2(src / f, out.parent / f)
    out.write_text(render_page(data, args.title), encoding="utf-8")
    if args.artifact:
        export_artifact(data, src, Path(args.artifact).resolve(), args.title, args.quality, args.max_px)
    n_err = sum(1 for e in data["entries"] if e.get("error"))
    n_img = sum(len(e["images"]) for e in data["entries"])
    print(f"画廊：{len(data['entries'])} 条 / {n_img} 张图 / {n_err} 条出错 → {out}")
    return 0


def export_artifact(data: dict, src: Path, dest: Path, title: str, quality: int, max_px: int) -> None:
    """Artifact 发布包：HTML 片段 + img/ 下转成 JPEG 的图（PNG 全量太大，超发布上限）。"""
    import copy
    import subprocess
    img = dest / "img"
    if dest.exists():
        shutil.rmtree(dest)
    img.mkdir(parents=True)
    data = copy.deepcopy(data)
    for e in data["entries"]:
        for theme, f in list(e["images"].items()):
            name = "img/" + hashlib.sha1(f.encode()).hexdigest()[:16] + ".jpg"
            subprocess.run(["sips", "-Z", str(max_px), "-s", "format", "jpeg", "-s", "formatOptions", str(quality),
                            str(src / f), "--out", str(dest / name)], check=True, capture_output=True)
            e["images"][theme] = name
    (dest / "index.html").write_text(render_page(data, title, artifact=True), encoding="utf-8")
    total = sum(p.stat().st_size for p in img.iterdir())
    print(f"Artifact 包：{len(list(img.iterdir()))} 张 JPEG，共 {total / 1e6:.1f} MB → {dest}")


def pixel_diff(pairs: list[dict]) -> dict:
    """调 ui-gallery-pixdiff.swift 逐像素比；swift 不可用时退回「字节不同即算变化」。"""
    import subprocess
    import tempfile
    if not pairs:
        return {}
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(pairs, f)
    try:
        res = subprocess.run(["swift", str(REPO / "scripts" / "ui-gallery-pixdiff.swift"), f.name],
                             check=True, capture_output=True, text=True)
        return json.loads(res.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as e:
        print(f"像素比对不可用（{e}），按文件字节判定", file=sys.stderr)
        return {p["key"]: {"changed": 1, "total": 1, "bbox": None} for p in pairs}
    finally:
        os.unlink(f.name)


def cmd_diff(args: argparse.Namespace) -> int:
    before_dir, after_dir = Path(args.before).resolve(), Path(args.after).resolve()
    before = {e["id"]: e for e in load_manifest(before_dir)["entries"]}
    after_m = load_manifest(after_dir)
    after = {e["id"]: e for e in after_m["entries"]}
    out = Path(args.out).resolve() if args.out else after_dir.parent / f"diff-{before_dir.name}-vs-{after_dir.name}" / "index.html"
    out.parent.mkdir(parents=True, exist_ok=True)

    def copy(e: dict | None, directory: Path, tag: str) -> dict:
        if not e:
            return {}
        res = {}
        for theme, f in e["images"].items():
            name = f"{tag}--{f}"
            shutil.copy2(directory / f, out.parent / name)
            res[theme] = name
        return res

    # 先按文件字节筛掉完全相同的，剩下的交给像素比对（时间戳这类必然变化只占几千像素）。
    candidates, pairs = [], []
    for eid in list(after.keys()) + [k for k in before if k not in after]:
        a, b = after.get(eid), before.get(eid)
        if a and b:
            themes = sorted(set(a["images"]) & set(b["images"]))
            differing = [t for t in themes
                         if digest(before_dir / b["images"][t]) != digest(after_dir / a["images"][t])]
            if not differing and set(a["images"]) == set(b["images"]):
                continue
            for t in differing:
                pairs.append({"key": f"{eid}\t{t}", "before": str(before_dir / b["images"][t]),
                              "after": str(after_dir / a["images"][t])})
            candidates.append((eid, "changed"))
        else:
            candidates.append((eid, "added" if a else "removed"))
    pix = pixel_diff(pairs)

    entries = []
    for eid, status in candidates:
        a, b = after.get(eid), before.get(eid)
        base = dict(a or b)
        if status == "changed":
            stats = {k.split("\t")[1]: v for k, v in pix.items() if k.split("\t")[0] == eid}
            changed = max((v.get("changed", 0) for v in stats.values()), default=0)
            total = max((v.get("total", 1) for v in stats.values()), default=1)
            if changed == 0 and stats:
                continue
            base["pixels"] = changed
            base["ratio"] = changed / total if total else 0
            base["bbox"] = {t: v.get("bbox") for t, v in stats.items()}
            base["minor"] = base["ratio"] < args.minor
        base["status"] = status
        base["before"] = copy(b, before_dir, "before")
        base["after"] = copy(a, after_dir, "after")
        base["images"] = base["after"] or base["before"]
        entries.append(base)
    entries.sort(key=lambda e: (e["status"] != "changed", -e.get("ratio", 1)))
    data = {"mode": "diff", "entries": entries, "total": len(set(before) | set(after)),
            "before": before_dir.name, "after": after_dir.name, "generatedAt": after_m.get("generatedAt")}
    out.write_text(render_page(data, args.title or "uTerm 界面画廊 · 改动前后"), encoding="utf-8")
    print(f"对比：{len(entries)} 处变化（共 {data['total']} 条）→ {out}")
    return 0


def cmd_collect(args: argparse.Namespace) -> int:
    """测试宿主带沙盒、图写不进仓库：从 xcresult 里导出附件，按原文件名落到出图目录。"""
    import subprocess
    import tempfile
    dest = Path(args.dir).resolve()
    dest.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", args.xcresult,
                        "--output-path", tmp], check=True, capture_output=True)
        index = json.loads((Path(tmp) / "manifest.json").read_text(encoding="utf-8"))
        n = 0
        for test in index:
            for a in test.get("attachments", []):
                # XCTest 给附件名加了「_<序号>_<UUID>」后缀：去掉，还原成测试里起的名字。
                name = re.sub(r"_\d+_[0-9A-F-]{36}(?=\.[a-z]+$)", "", a["suggestedHumanReadableName"])
                shutil.copy2(Path(tmp) / a["exportedFileName"], dest / name)
                n += 1
    print(f"从 {args.xcresult} 导出 {n} 个附件 → {dest}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build", help="出图目录 → 画廊 HTML")
    b.add_argument("dir")
    b.add_argument("--out")
    b.add_argument("--title", default="uTerm 界面画廊")
    b.add_argument("--artifact", help="另出一份 Artifact 发布包到这个目录（片段 HTML + JPEG）")
    b.add_argument("--quality", type=int, default=78, help="Artifact 包 JPEG 质量")
    b.add_argument("--max-px", type=int, default=1920, help="Artifact 包图片长边上限（像素）")
    b.set_defaults(func=cmd_build)
    c = sub.add_parser("collect", help="xcresult 里的附件 → 出图目录（测试宿主写不进仓库时用）")
    c.add_argument("xcresult")
    c.add_argument("dir")
    c.set_defaults(func=cmd_collect)
    d = sub.add_parser("diff", help="两次出图 → 只列变化的对比页")
    d.add_argument("before")
    d.add_argument("after")
    d.add_argument("--out")
    d.add_argument("--title")
    d.add_argument("--minor", type=float, default=0.002,
                   help="变化像素占比低于它算「微小」（时间戳之类），默认 0.2%%，页面里默认折叠")
    d.set_defaults(func=cmd_diff)
    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
