// Demo content for the disposable customer fixture: notes and tasks that carry
// files, attachments, links and messages, so the record panels can be reviewed
// with real records instead of an empty workspace.
//
//   node test/seed-demo-workspace.mjs --url http://127.0.0.1:8091
//
// The fixture runs this itself when NRC_FIXTURE_SEED=1 is set (see
// test/customer-workspace-dev.mjs). Writes go through the Go CLI, which speaks
// the NRC protocol: the same paths the client uses, only without a browser.
import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));

function parseArgs(argv) {
  const options = { url: "http://127.0.0.1:8091", workspace: "workspace1", cli: process.env.NRC_CLI_BIN || "", keep: false };
  for (let index = 0; index < argv.length; index += 1) {
    const [flag, inlineValue] = argv[index].split("=");
    const value = inlineValue ?? argv[index + 1];
    if (flag === "--url") options.url = value;
    else if (flag === "--workspace") options.workspace = value;
    else if (flag === "--cli") options.cli = value;
    else if (flag === "--keep") options.keep = true;
    else throw new Error(`Unknown argument ${argv[index]}`);
    if (inlineValue === undefined && flag !== "--keep") index += 1;
  }
  options.url = options.url.replace(/\/+$/, "");
  return options;
}

// The demo files are written here so the uploads carry real bytes: the fixture
// serves them back from /files/, exactly like the tailscale-proxy does.
function pdfBytes(title, subtitle) {
  const escape = (value) => value.replace(/[\\()]/g, "\\$&");
  const body = `BT /F1 18 Tf 60 760 Td (${escape(title)}) Tj 0 -28 Td /F1 11 Tf (${escape(subtitle)}) Tj ET`;
  return Buffer.from(
    "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n" +
    "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj\n" +
    `4 0 obj<</Length ${body.length}>>stream\n${body}\nendstream\nendobj\n` +
    "5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n",
    "utf8");
}

const DEMO_FILES = {
  "wartungsvertrag.pdf": { mimeType: "application/pdf", bytes: pdfBytes("Wartungsvertrag 2026", "Standort Nord - Service und Pruefung") },
  "nachtrag-2026.pdf": { mimeType: "application/pdf", bytes: pdfBytes("Nachtrag 2026", "Reaktionszeiten und Ersatzteile") },
  "preisblatt-2027.pdf": { mimeType: "application/pdf", bytes: pdfBytes("Preisblatt 2027", "Konditionen Standort Nord") },
  "messprotokoll-nordtor.csv": {
    mimeType: "text/csv",
    bytes: Buffer.from(
      "zyklus;zeit;induktivitaet_mh;bemerkung\n1;06:00;1.42;Fehler 14 gemeldet\n2;09:30;1.38;unauffaellig\n3;12:00;1.41;unauffaellig\n",
      "utf8"),
  },
  "grundriss-halle-2.svg": {
    mimeType: "image/svg+xml",
    bytes: Buffer.from(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 200" role="img" aria-label="Grundriss Halle 2">' +
      '<rect width="320" height="200" fill="#f5f5f5" stroke="#111"/>' +
      '<rect x="24" y="24" width="150" height="90" fill="none" stroke="#00aeef" stroke-width="2"/>' +
      '<rect x="196" y="24" width="100" height="150" fill="none" stroke="#ffb700" stroke-width="2"/>' +
      '<text x="24" y="140" font-family="monospace" font-size="12" fill="#111">HALLE 2 / NORDTOR</text></svg>',
      "utf8"),
  },
};

async function resolveCli(options, workdir) {
  if (options.cli) return options.cli;
  const binary = path.join(workdir, "nrc");
  await new Promise((resolve, reject) => {
    execFile("go", ["build", "-o", binary, "./cmd/nrc"], { cwd: path.join(repoRoot, "cli") }, (error, stdout, stderr) => {
      if (error) reject(new Error(`building the CLI failed: ${stderr || error.message}`));
      else resolve(stdout);
    });
  });
  return binary;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const workdir = await fs.mkdtemp(path.join(os.tmpdir(), "nrc-seed-"));
  const home = path.join(workdir, "home");
  const cli = await resolveCli(options, workdir);
  const wsUrl = options.url.replace(/^http/, "ws");
  await fs.mkdir(path.join(home, ".config/nrc"), { recursive: true });
  await fs.writeFile(path.join(home, ".config/nrc/config.yaml"),
    `server: "${wsUrl}/"\nworkspace_id: "${options.workspace}"\nroom_id: 2\nproxy_url: "${options.url}"\n`, "utf8");
  for (const [name, file] of Object.entries(DEMO_FILES)) await fs.writeFile(path.join(workdir, name), file.bytes);

  const cliCall = (args) => new Promise((resolve, reject) => {
    execFile(cli, args, { env: { ...process.env, HOME: home }, maxBuffer: 32 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) return reject(new Error(`${args[0]} ${args[1] ?? ""} failed: ${stderr || error.message}`));
      try { resolve(JSON.parse(stdout)); } catch { resolve({ raw: stdout }); }
    });
  });
  const created = [];
  const mutate = async (...args) => {
    const result = await cliCall(args);
    if (result.id === undefined) throw new Error(`${args.join(" ")} returned no id: ${JSON.stringify(result)}`);
    created.push(`${result.resource_type ?? args[0]} #${result.id}`);
    return result.id;
  };
  // The fixture proxy answers before its backend accepts connections, so the
  // first call doubles as the readiness gate.
  const waitForBackend = async () => {
    for (let attempt = 0; attempt < 240; attempt += 1) {
      try { await cliCall(["status"]); return; }
      catch { await new Promise((resolve) => setTimeout(resolve, 250)); }
    }
    throw new Error("the fixture backend never accepted connections");
  };
  const upload = async (name, extra) => {
    const result = await cliCall(["file", "upload", path.join(workdir, name), ...extra]);
    const resource = result.resource ?? {};
    const id = result.id ?? resource.id;
    const attachment = (resource.attachments ?? resource.attachment ?? [])[0];
    created.push(`file #${id}`);
    return { id, path: path.join(workdir, name), attachment };
  };

  await waitForBackend();

  // Reusable File assets. Each one is an upload plus metadata, so the FILES
  // register shows a real title, category and attachment size.
  const contract = await upload("wartungsvertrag.pdf", ["--title", "Wartungsvertrag 2026", "--description", "Service und Prüfung für Standort Nord.", "--category", "Vertrag", "--tag", "vertrag"]);
  const addendum = await upload("nachtrag-2026.pdf", ["--title", "Nachtrag 2026", "--description", "Reaktionszeiten und Ersatzteile.", "--category", "Vertrag", "--tag", "vertrag"]);
  const priceList = await upload("preisblatt-2027.pdf", ["--title", "Preisblatt 2027", "--description", "Konditionen für die Verlängerung.", "--category", "Vertrag", "--tag", "preise"]);
  const protocol = await upload("messprotokoll-nordtor.csv", ["--title", "Messprotokoll Nordtor", "--description", "Messreihe des Schrankenservice.", "--category", "Messprotokoll", "--tag", "messung"]);
  const plan = await upload("grundriss-halle-2.svg", ["--title", "Grundriss Halle 2", "--description", "Lageplan Nordtor und Anlage 2.", "--category", "Plan", "--tag", "lageplan"]);

  // Tasks: one with an attachment, one with a second attachment, one plain.
  const barrier = await mutate("task", "create", "Nordtor Schranke prüfen",
    "--description", "## Messprotokoll\n\nSchranke meldet **Fehler 14** nach dem 06:00-Zyklus.\n\n| Zyklus | L (mH) |\n|---|---|\n| 1 | 1.42 |\n| 2 | 1.38 |\n\n- [x] Messreihe dokumentiert\n- [ ] Drehmomenttabelle nachtragen",
    "--project", "site-north", "--priority", "128", "--attach", path.join(workdir, "messprotokoll-nordtor.csv"));
  await cliCall(["task", "update", String(barrier), "--status", "todo"]);
  const renewal = await mutate("task", "create", "Wartungsvertrag verlängern",
    "--description", "Konditionen für 2027 prüfen und den Vertrag verlängern.\n\n> Laufzeit endet am 31.12.",
    "--project", "verwaltung", "--priority", "64",
    "--attach", `${path.join(workdir, "wartungsvertrag.pdf")},${path.join(workdir, "nachtrag-2026.pdf")}`);
  await cliCall(["task", "update", String(renewal), "--status", "progress"]);
  const torque = await mutate("task", "create", "Drehmomenttabelle nachtragen",
    "--description", "Werte aus dem Service in das Messprotokoll übernehmen.", "--project", "site-north", "--priority", "32");

  // Notes: one with an attachment, one plain. Both carry links.
  const planning = await mutate("note", "create", "Wartungsplanung Nord",
    "--content", "# Wartungsplanung Nord\n\nDie Anlage wird **Oktober** geprüft.\n\n- Zyklus 1: Sichtprüfung\n- Zyklus 2: Drehmomenttabelle\n\nLageplan liegt als Anhang bei.",
    "--project", "site-north", "--tag", "wartung",
    "--attach", `${path.join(workdir, "grundriss-halle-2.svg")},${path.join(workdir, "messprotokoll-nordtor.csv")}`);
  const handover = await mutate("note", "create", "Schichtübergabe KW 39",
    "--content", "# Schichtübergabe KW 39\n\n1. Nordtor beobachtet, Fehler 14 offen\n2. Vertragsverlängerung liegt bei der Verwaltung\n\nNächste Schicht: Schranke nach dem 06:00-Zyklus prüfen.\n\nQuelle: [Nordtor Fehler 14](https://ampcode.com/threads/T-01a05d01-383f-71a9-b9e6-c7debb8c7bd9)",
    "--project", "site-north", "--tag", "uebergabe");

  // Links: files into the records, records into each other.
  const link = (sourceType, sourceId, targetType, targetId, relation) =>
    mutate("edge", "create", "--source-type", sourceType, "--source-id", String(sourceId),
      "--target-type", targetType, "--target-id", String(targetId), "--relation", relation);
  await link("task", barrier, "asset", protocol.id, "related-to");
  await link("task", barrier, "task", torque, "related-to");
  await link("task", renewal, "asset", contract.id, "references");
  await link("task", renewal, "asset", addendum.id, "references");
  await link("task", renewal, "asset", priceList.id, "references");
  await link("asset", planning, "asset", plan.id, "related-to");
  await link("asset", planning, "asset", contract.id, "related-to");
  await link("asset", planning, "task", barrier, "references");
  await link("asset", handover, "asset", planning, "references");

  // One slice, so the tasks view opens on a populated register instead of an
  // empty grouping. Membership is the same member-of edge the slice record folds.
  await mutate("slice", "create", "Wartung Nordtor Q4", "--owner", "customer-preview", "--outcome", "Anlage läuft störungsfrei");
  await cliCall(["slice", "assign", "Wartung Nordtor Q4", "--task", String(barrier), "--task", String(renewal), "--task", String(torque),
    "--note", String(planning), "--file", String(contract.id), "--file", String(addendum.id), "--file", String(plan.id)]);
  created.push("slice Wartung Nordtor Q4");

  // Messages, so the record panels show a stream and the strip its preview.
  const message = (parentType, parentId, preview, payload) =>
    mutate("asset", "create", preview, payload, "--type", "comment", "--parent-type", parentType, "--parent-id", String(parentId));
  await message("task", barrier, "Schranke meldet Fehler 14 nach dem 06:00-Zyklus.", "## Messprotokoll Loop B\n\n- [x] Messreihe dokumentiert\n- [ ] Tabelle nachtragen");
  await message("task", barrier, "Werte liegen im Anhang.", "Die CSV aus dem Service liegt am Task.\n\n| Zyklus | L (mH) |\n|---|---|\n| 1 | 1.42 |");
  await message("task", barrier, "Tor bleibt bis zur Freigabe gesperrt.", "Tor bleibt bis zur Freigabe gesperrt.");
  await message("task", renewal, "Laufzeit endet am 31.12.", "Laufzeit endet am 31.12., Verlängerung ist angefragt.");
  await message("asset", planning, "Oktober passt.", "Oktober passt, Halle 2 ist dann frei.");
  await message("asset", planning, "Lageplan hängt an.", "Der **Lageplan** hängt als Anhang an dieser Notiz.");

  console.log(`Seeded ${created.length} records into workspace ${options.workspace}:`);
  console.log(`  ${created.join(", ")}`);
  console.log(`  tasks: #${barrier} Nordtor Schranke prüfen, #${renewal} Wartungsvertrag verlängern, #${torque} Drehmomenttabelle nachtragen`);
  console.log(`  notes: #${planning} Wartungsplanung Nord, #${handover} Schichtübergabe KW 39`);
  console.log(`  files: #${contract.id} Wartungsvertrag 2026, #${addendum.id} Nachtrag 2026, #${priceList.id} Preisblatt 2027, #${protocol.id} Messprotokoll Nordtor, #${plan.id} Grundriss Halle 2`);
  if (!options.keep) await fs.rm(workdir, { recursive: true, force: true });
}

main().catch((error) => {
  console.error(`Seeding failed: ${error.message}`);
  process.exit(1);
});
