// Build a Jazzer working corpus from the Odin-generated protocol corpus.
//
// The Odin seed generator writes one frame per opcode from the server
// serializers; client/fuzz/build-seeds.cjs adds the response frames that have no
// Odin parser. This script copies every supported response frame and fails when
// a committed seed no longer decodes or an opcode has no seed, so a wire change
// cannot silently shrink the campaign.

const fs = require("node:fs");
const path = require("node:path");
const protocol = require("../protocol.js");
const retained = require("../retained-messages.js");
const { decodeServerFrame, SUPPORTED_OPCODES } = require("../frames.js");

const repoRoot = path.resolve(__dirname, "../..");
const sourceDirs = [
  path.join(repoRoot, "test", "protocol_fuzz", "corpus"),
  path.join(__dirname, "corpus"),
];
const targetDir = process.argv[2];

if (!targetDir) {
  console.error("usage: node client/fuzz/seed-corpus.cjs <target-directory>");
  process.exit(2);
}

// Keep inputs Jazzer discovered in earlier campaigns; only the named seeds
// below are overwritten. The Odin runner grows its working corpus the same way.
fs.mkdirSync(targetDir, { recursive: true });

const supported = new Set(SUPPORTED_OPCODES);
const seen = new Map();
let copied = 0;

for (const sourceDir of sourceDirs) {
  for (const name of fs.readdirSync(sourceDir).sort()) {
    if (!name.endsWith(".bin")) continue;
    const bytes = fs.readFileSync(path.join(sourceDir, name));
    if (bytes.length < 2) continue;
    const opcode = bytes.readUInt16BE(0);
    if (!supported.has(opcode)) continue;

    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    try {
      decodeServerFrame(view);
    } catch (error) {
      if (error instanceof protocol.ProtocolError || error instanceof retained.ProtocolError) {
        console.error(`${name}: committed seed no longer decodes: ${error.message}`);
        process.exit(1);
      }
      throw error;
    }

    fs.copyFileSync(path.join(sourceDir, name), path.join(targetDir, name));
    seen.set(opcode, name);
    copied += 1;
  }
}

const missing = SUPPORTED_OPCODES.filter((opcode) => !seen.has(opcode));
if (missing.length) {
  console.error(`missing response seeds for opcodes: ${missing.join(", ")}`);
  process.exit(1);
}

console.log(`copied ${copied} seeds covering ${seen.size} response opcodes to ${targetDir}`);
