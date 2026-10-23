// Opt-in Jazzer.js target for the shared client protocol and frame decoders.
//
// Run through test/run_js_protocol_fuzz.sh. A ProtocolError is a normal result
// for mutated input; any other exception is a finding. The decoder requires the
// whole frame to be consumed, so trailing bytes also surface as ProtocolError.

const protocol = require("../protocol.js");
const retained = require("../retained-messages.js");
const { decodeServerFrame } = require("../frames.js");

const MAX_FRAME_BYTES = 128 * 1024;

module.exports.fuzz = function fuzz(data) {
  if (data.length < 2 || data.length > MAX_FRAME_BYTES) return;
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  try {
    decodeServerFrame(view);
  } catch (error) {
    if (error instanceof protocol.ProtocolError || error instanceof retained.ProtocolError) return;
    throw error;
  }
};
