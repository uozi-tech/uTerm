// node --test .github/cla/   （Node 20+，无依赖）
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import * as cla from "./lib.mjs";
import { main } from "./run.mjs";

const commit = (sha, author, extra = {}) => ({
  sha,
  author,
  commit: { author: { name: author?.login ?? "Someone", email: "x@example.com" }, message: "change", ...extra },
});
const alice = { id: 1, login: "alice", type: "User" };
const bob = { id: 2, login: "Bob", type: "User" };

test("签署语句：整条评论就是这句话才算，忽略大小写与空白", () => {
  assert.ok(cla.isSignComment(cla.SIGN_PHRASE));
  assert.ok(cla.isSignComment("  " + cla.SIGN_PHRASE.toUpperCase().replace(/ /g, "  ") + "\n"));
  assert.ok(!cla.isSignComment(cla.SIGN_PHRASE + " thanks"));
  assert.ok(!cla.isSignComment("> " + cla.SIGN_PHRASE));
  assert.ok(cla.isRecheckComment(" Recheck "));
});

test("需要签的人：按账号去重，机器人与 allowlist 排除", () => {
  const allow = cla.parseAllowlist("# 注释\nmaintainer\nci-*\n");
  const commits = [
    commit("a1", alice),
    commit("a2", { ...alice }),
    commit("b1", bob),
    commit("d1", { id: 3, login: "dependabot[bot]", type: "Bot" }),
    commit("m1", { id: 4, login: "Maintainer", type: "User" }),
    commit("c1", { id: 5, login: "ci-runner", type: "User" }),
  ];
  const { people, unlinked } = cla.requiredSigners(commits, allow);
  assert.deepEqual([...people.keys()].sort(), ["alice", "bob"]);
  assert.equal(unlinked.length, 0);
});

test("作者邮箱没关联账号：noreply 邮箱认得出就按登录名，认不出就挡住", () => {
  const commits = [
    { sha: "n1234567", author: null, commit: { author: { name: "Carol", email: "77+carol@users.noreply.github.com" }, message: "" } },
    { sha: "u7654321", author: null, commit: { author: { name: "Dave", email: "dave@corp.example" }, message: "" } },
  ];
  const { people, unlinked } = cla.requiredSigners(commits, []);
  assert.deepEqual([...people.keys()], ["carol"]);
  assert.deepEqual(unlinked, [{ name: "Dave", email: "dave@corp.example", sha: "u765432" }]);
});

test("Co-authored-by 也要签；机器人共同作者不算", () => {
  const message = "fix\n\nCo-authored-by: Erin <erin@users.noreply.github.com>\nCo-Authored-By: Claude[bot] <noreply@anthropic.com>\nco-authored-by: Frank <frank@corp.example>";
  const { people, unlinked } = cla.requiredSigners([commit("c1", alice, { message })], []);
  assert.deepEqual([...people.keys()].sort(), ["alice", "erin"]);
  assert.deepEqual(unlinked.map((u) => u.name), ["Frank"]);
});

test("已签判断按账号 id（登录名改了也认），只认同一版本", () => {
  const sigs = [{ id: 1, login: "alice-old-name", claVersion: cla.CLA_VERSION }, { id: 2, login: "bob", claVersion: "0.9" }];
  assert.ok(cla.hasSigned(alice, sigs));
  assert.ok(!cla.hasSigned(bob, sigs), "旧版本的签名不算");
  assert.ok(cla.hasSigned({ login: "ALICE-OLD-NAME" }, sigs), "没有 id 时按登录名");
});

test("addSignature 不重复记", () => {
  const rec = { id: 1, login: "alice", claVersion: cla.CLA_VERSION };
  const once = cla.addSignature([], rec);
  assert.equal(once.length, 1);
  assert.equal(cla.addSignature(once, { ...rec, pr: 9 }), once);
});

test("评论文案：没签时列出人与签署语句，全签时简短", () => {
  const bad = cla.evaluate({ commits: [commit("a1", alice)], allowlist: [], signatures: [] });
  const body = cla.renderComment({ result: bad, documentUrl: "https://e.x/CLA.md" });
  assert.ok(body.startsWith(cla.MARKER));
  assert.ok(body.includes(cla.SIGN_PHRASE) && body.includes("@alice") && body.includes("https://e.x/CLA.md"));
  assert.equal(cla.statusFor(bad).state, "failure");
  const good = cla.evaluate({ commits: [commit("a1", alice)], allowlist: [], signatures: [{ id: 1, login: "alice", claVersion: cla.CLA_VERSION }] });
  assert.equal(cla.statusFor(good).state, "success");
  assert.ok(!cla.renderComment({ result: good, documentUrl: "u" }).includes(cla.SIGN_PHRASE));
});

// ---- run.mjs：假 GitHub API，走一遍「评论签署 → 写签名 → status 变绿 → 更新评论」 ----

function fakeGitHub({ signatures = null, comments = [] } = {}) {
  const calls = [];
  let file = signatures === null ? null : { sha: "s1", body: signatures };
  const json = (status, body) => new Response(body === undefined ? null : JSON.stringify(body), { status });
  globalThis.fetch = async (url, init = {}) => {
    const path = new URL(url).pathname + new URL(url).search;
    const method = init.method ?? "GET";
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ method, path, body, auth: init.headers?.authorization });
    if (path.startsWith("/repos/org/sigs/contents/")) {
      if (method === "GET") return file ? json(200, { sha: file.sha, content: Buffer.from(JSON.stringify(file.body)).toString("base64") }) : json(404, {});
      file = { sha: "s2", body: JSON.parse(Buffer.from(body.content, "base64").toString()) };
      return json(200, {});
    }
    if (path === "/repos/org/app/pulls/7") return json(200, { head: { sha: "headsha" } });
    if (path.startsWith("/repos/org/app/pulls/7/commits")) return json(200, [commit("a1", alice)]);
    if (path.startsWith("/repos/org/app/issues/7/comments")) return method === "GET" ? json(200, comments) : json(201, {});
    if (path.startsWith("/repos/org/app/issues/comments/")) return json(200, {});
    if (path === "/repos/org/app/statuses/headsha") return json(201, {});
    return json(500, { unexpected: path });
  };
  return { calls, file: () => file };
}

function withEvent(name, payload) {
  const dir = mkdtempSync(join(tmpdir(), "cla-"));
  writeFileSync(join(dir, "event.json"), JSON.stringify(payload));
  Object.assign(process.env, {
    GITHUB_EVENT_PATH: join(dir, "event.json"), GITHUB_EVENT_NAME: name, GITHUB_REPOSITORY: "org/app",
    GITHUB_TOKEN: "repo-token", CLA_SIGNATURES_TOKEN: "sig-token", CLA_SIGNATURES_REPO: "org/sigs",
    CLA_SIGNATURES_PATH: "signatures/cla-v1.json", CLA_DOCUMENT_URL: "https://e.x/CLA.md",
  });
}

test("PR 打开：没签 → status 失败、发一条说明评论；签名仓库只用签名 token", async () => {
  const gh = fakeGitHub();
  withEvent("pull_request_target", { pull_request: { number: 7 } });
  await main();
  const status = gh.calls.find((c) => c.path === "/repos/org/app/statuses/headsha");
  assert.equal(status.body.state, "failure");
  assert.equal(status.body.context, "cla");
  const posted = gh.calls.find((c) => c.method === "POST" && c.path === "/repos/org/app/issues/7/comments");
  assert.ok(posted.body.body.includes(cla.SIGN_PHRASE));
  for (const c of gh.calls) {
    assert.equal(c.auth, c.path.startsWith("/repos/org/sigs/") ? "Bearer sig-token" : "Bearer repo-token");
  }
});

test("评论签署：记下签名（以评论为证）→ status 成功 → 原评论改成「都已签」", async () => {
  const existing = [{ id: 99, user: { login: "github-actions[bot]", type: "Bot" }, body: cla.MARKER + "\nold" }];
  const gh = fakeGitHub({ signatures: [], comments: existing });
  withEvent("issue_comment", {
    issue: { number: 7, pull_request: {} },
    comment: { id: 555, user: alice, body: cla.SIGN_PHRASE, created_at: "2026-11-20T00:00:00Z", html_url: "https://e.x/c/555" },
  });
  await main();
  const saved = gh.file().body;
  assert.equal(saved.length, 1);
  assert.equal(saved[0].id, 1);
  assert.equal(saved[0].commentUrl, "https://e.x/c/555");
  assert.equal(saved[0].claVersion, cla.CLA_VERSION);
  assert.equal(gh.calls.find((c) => c.path.endsWith("/statuses/headsha")).body.state, "success");
  const patched = gh.calls.find((c) => c.method === "PATCH");
  assert.equal(patched.path, "/repos/org/app/issues/comments/99");
  assert.ok(!gh.calls.some((c) => c.method === "POST" && c.path.endsWith("/issues/7/comments")), "已有评论就改，不再新发");
});

test("无关评论什么都不做", async () => {
  const gh = fakeGitHub();
  withEvent("issue_comment", { issue: { number: 7, pull_request: {} }, comment: { id: 1, user: alice, body: "LGTM" } });
  await main();
  assert.equal(gh.calls.length, 0);
});
