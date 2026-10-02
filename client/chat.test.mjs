import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const window = {};
vm.runInNewContext(readFileSync(new URL("chat.js", import.meta.url), "utf8"), { window });
const chat = window.NRCChat;

test("entity completion unifies tasks and notes without losing IDs or suffix text", () => {
  const text = "See #release plan suffix";
  const caret = text.indexOf(" suffix");
  const entries = [
    { type: "task", id: "18446744073709551615", title: "Release plan" },
    { type: "note", id: "18446744073709551615", title: "Release plan notes" },
    { type: "note", id: "18446744073709551615", title: "Release plan notes" },
    { type: "task", id: "7", title: "Other" },
  ];
  const result = chat.referenceSuggestions(text, caret, entries);
  assert.equal(text.slice(...result.replaceRange), "#release plan");
  assert.deepEqual(Array.from(result.suggestions, (s) => s.label), ["[task:18446744073709551615]", "[note:18446744073709551615]"]);
  assert.equal(chat.referenceSuggestions("#184", 4, entries).suggestions.length, 2);
  assert.equal(chat.referenceSuggestions("#plan release", 13, entries).suggestions.length, 2);
  for (const text of ["plain", "word#12", "#title\nnext"]) assert.equal(chat.referenceQuery(text, text.length), null);
  assert.equal(chat.referenceSuggestions("#", 1, entries).suggestions.length, 3);
});

test("server-discovered titles replace incomplete cached entries and retain semantic matches", () => {
  const result = chat.referenceSuggestions("#launch", 7, [
    { type: "task", id: "7", title: "" },
    { type: "task", id: "7", title: "Rollout checklist", remote: true },
    { type: "note", id: "8", title: "Deployment guide", remote: true },
    { type: "task", id: "9", title: "Unrelated cached task" },
  ]);
  assert.equal(result.suggestions.length, 2);
  assert.equal(result.suggestions.find((item) => item.label === "[task:7]").title, "Rollout checklist");
});

test("mentions match complete identities, not email addresses or longer names", () => {
  const pattern = chat.mentionPattern("ben");
  for (const text of ["@ben", "Hi @BEN!", "(@ben)", "@ben.", "\n@ben: ready"]) assert.ok(pattern.test(text), text);
  for (const text of ["a@ben", "@benny", "@ben-smith", "@ben.example", "@@ben", "@ben_2"]) assert.ok(!pattern.test(text), text);
  assert.ok(chat.mentionPattern("a.b").test("@a.b!"));
  assert.ok(!chat.mentionPattern("a.b").test("@axb!"));
  assert.ok(chat.mentionPattern("jörg").test("@JÖRG"));
});

test("mention completion replaces only the current token and deduplicates presence", () => {
  const text = "First line\nHi @an suffix";
  const caret = text.indexOf(" suffix");
  const result = chat.suggestions(text, caret, ["anna", "andy", "anna", "ben"]);
  assert.deepEqual(Array.from(result.suggestions, (item) => item.label), ["@andy", "@anna"]);
  assert.equal(text.slice(...result.replaceRange), "@an");
  assert.equal(chat.suggestions("a@ben", 5, ["ben"]), null);
  assert.equal(chat.suggestions("@ben done", 9, ["ben"]), null);
});

test("quote text is bounded, multiline, escaped Markdown and preserves an empty reply line", () => {
  const quote = chat.quoteText("anna\nforged", "one\n\n![image](https://example.com)\n<script>");
  assert.ok(quote.startsWith("> anna forged:\n> one\n> \n"));
  assert.ok(quote.includes("\\!\\[image\\]"));
  assert.ok(quote.includes("\\<script\\>"));
  assert.ok(quote.endsWith("\n\n"));
  assert.ok(chat.quoteText("anna", "x".repeat(3000)).length < 2050);
});
