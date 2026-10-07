import { AutoProcessor, RawImage, env } from '@huggingface/transformers';
import * as ort from 'onnxruntime-node';
import sharp from 'sharp';
import { stat, realpath, readFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';

export const MODEL_REVISION = 'daa72c51243991dfcaf9f9137d2c573d8f7790c0';
export const MAX_SAMPLES = 480000;
export const MAX_LINE = 8192;
const MAX_FILE = 128 * 1024 * 1024;
const MAX_PIXELS = 16 * 1024 * 1024;
env.allowRemoteModels = false;
env.allowLocalModels = true;
env.useBrowserCache = false;
sharp.concurrency(1);
sharp.cache(false);

export function validateRequest(request) {
  if (!request || !['image', 'audio'].includes(request.kind)) throw new Error('invalid kind');
  if (typeof request.path !== 'string' || !isAbsolute(request.path) || request.path.includes('\0')) throw new Error('local absolute path required');
  const offset = request.offset ?? 0;
  if (!Number.isFinite(offset) || offset < 0 || offset > 1e9) throw new Error('invalid offset');
  return { ...request, offset };
}

async function localFile(path) {
  const resolved = await realpath(path);
  const info = await stat(resolved);
  if (!info.isFile() || info.size > MAX_FILE) throw new Error('media file exceeds limit or is not regular');
  return resolved;
}

export async function decodeImage(path) {
  // Probe and decode the same bounded bytes, avoiding a path replacement between checks.
  const bytes = await readFile(await localFile(path));
  if (bytes.length > MAX_FILE) throw new Error('image exceeds file limit');
  const options = { limitInputPixels: MAX_PIXELS, failOn: 'warning', animated: false };
  const metadata = await sharp(bytes, options).metadata();
  if (!metadata.width || !metadata.height || metadata.width > 8192 || metadata.height > 8192 ||
      metadata.width * metadata.height > MAX_PIXELS || (metadata.pages ?? 1) > 1) throw new Error('image dimensions exceed limit');
  const { data, info } = await sharp(bytes, options).raw().toBuffer({ resolveWithObject: true });
  return new RawImage(new Uint8ClampedArray(data), info.width, info.height, info.channels);
}

export async function decodeAudio(path, offset = 0) {
  path = await localFile(path);
  return new Promise((resolve, reject) => {
    const child = spawn('ffmpeg', ['-nostdin', '-v', 'error', '-threads', '1',
      '-protocol_whitelist', 'file,pipe',
      '-format_whitelist', 'wav,mp3,flac,ogg,mov,matroska,webm,aac',
      '-ss', String(offset), '-i', path,
      '-map', '0:a:0', '-t', '30', '-vn', '-threads', '1', '-ac', '1', '-ar', '16000',
      '-f', 'f32le', 'pipe:1'], { stdio: ['ignore', 'pipe', 'pipe'] });
    const chunks = [];
    let size = 0, failure;
    const timer = setTimeout(() => { failure = 'audio decode timeout'; child.kill('SIGKILL'); }, 30000);
    child.stdout.on('data', chunk => {
      size += chunk.length;
      if (size > MAX_SAMPLES * 4) { failure = 'audio exceeds segment limit'; child.kill('SIGKILL'); }
      else chunks.push(chunk);
    });
    child.stderr.resume();
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('close', code => {
      clearTimeout(timer);
      if (failure || code !== 0 || size % 4) return reject(new Error(failure ?? 'invalid audio or unavailable decoder'));
      const bytes = Buffer.concat(chunks);
      const samples = new Float32Array(size / 4);
      for (let i = 0; i < samples.length; i++) samples[i] = bytes.readFloatLE(i * 4);
      if (!samples.every(Number.isFinite)) return reject(new Error('invalid audio samples'));
      resolve(samples);
    });
  });
}

const CONTRACTS = {
  image: { inputs: { pixel_values: ['float32', [1, 2520, 768]], pixel_position_ids: ['int64', [1, 2520, 2]] }, output: 'image_features' },
  audio: { inputs: { input_features: ['float32', [1, null, 128]], input_features_mask: ['bool', [1, null]] }, output: 'audio_features' },
};

export function validateSession(session, kind) {
  const contract = CONTRACTS[kind];
  const check = (meta, type, shape) => meta?.isTensor && meta.type === type && meta.shape.length === shape.length &&
    shape.every((d, i) => d === null || typeof meta.shape[i] === 'string' || meta.shape[i] === d);
  if (session.inputNames.length !== Object.keys(contract.inputs).length) throw new Error('unexpected encoder inputs');
  for (const [name, [type, shape]] of Object.entries(contract.inputs)) {
    const meta = session.inputMetadata[session.inputNames.indexOf(name)];
    if (!check(meta, type, shape)) throw new Error(`encoder metadata mismatch: ${name}`);
  }
  const output = session.outputMetadata[session.outputNames.indexOf(contract.output)];
  if (!check(output, 'float32', [null, 512])) throw new Error('encoder output metadata mismatch');
}

export function createWorker(modelDir = process.env.MEDIA_MODEL_DIR) {
  let processor;
  const sessions = new Map();
  let queue = Promise.resolve();
  async function processRequest(input) {
    const request = validateRequest(input);
    const media = request.kind === 'image' ? await decodeImage(request.path) : await decodeAudio(request.path, request.offset);
    if (request.kind === 'audio' && media.length === 0) return { features: [], tokens: 0 };
    if (!modelDir || !isAbsolute(modelDir)) throw new Error('MEDIA_MODEL_DIR must be a local absolute directory');
    processor ??= await AutoProcessor.from_pretrained(modelDir, { local_files_only: true, revision: MODEL_REVISION });
    if (processor.constructor.name !== 'EmbeddingGemma2Processor') throw new Error('expected EmbeddingGemma2Processor');
    const prepared = request.kind === 'image' ? await processor.image_processor([media]) : await processor._process_audio([media]);
    const tokens = (request.kind === 'image' ? prepared.num_soft_tokens_per_image : prepared.num_soft_tokens_per_audio)[0];
    if (!Number.isInteger(tokens) || tokens < 0 || tokens > 750) throw new Error('invalid placeholder count');
    if (!tokens) return { features: [], tokens: 0 };
    if (!sessions.has(request.kind)) {
      // Keep only the active modality resident alongside Go's text backbone.
      // Retaining both large encoders can exhaust memory on mixed workspaces.
      for (const session of sessions.values()) await session.release();
      sessions.clear();
      const session = await ort.InferenceSession.create(join(modelDir, 'onnx', `${request.kind === 'image' ? 'vision' : 'audio'}_encoder.onnx`),
        { executionProviders: ['cpu'], intraOpNumThreads: 1, interOpNumThreads: 1, executionMode: 'sequential' });
      try { validateSession(session, request.kind); } catch (error) { await session.release(); throw error; }
      sessions.set(request.kind, session);
    }
    const feeds = {};
    for (const name of Object.keys(CONTRACTS[request.kind].inputs)) {
      const tensor = prepared[name === 'pixel_position_ids' ? 'image_position_ids' : name];
      feeds[name] = new ort.Tensor(tensor.type, tensor.data, tensor.dims);
    }
    const result = (await sessions.get(request.kind).run(feeds))[CONTRACTS[request.kind].output];
    if (result.dims.length !== 2 || result.dims[0] !== tokens || result.dims[1] !== 512 || !result.data.every(Number.isFinite)) throw new Error('encoder feature shape/count mismatch');
    return { features: Array.from(result.data), tokens };
  }
  return {
    handle(input) {
      const next = queue.then(() => processRequest(input)).catch(error => ({ error: error.message }));
      queue = next.then(() => {});
      return next;
    },
    async close() { await queue; for (const session of sessions.values()) await session.release(); },
  };
}

export async function runProtocol(input, output, worker) {
  let chunks = [], size = 0, oversized = false;
  async function finish() {
    let response;
    if (oversized) response = { error: 'request exceeds line limit' };
    else {
      try { response = await worker.handle(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch { response = { error: 'invalid JSON request' }; }
    }
    let line = JSON.stringify(response);
    if (Buffer.byteLength(line) > 16 * 1024 * 1024) line = JSON.stringify({ error: 'response exceeds limit' });
    if (!output.write(line + '\n')) await new Promise(resolve => output.once('drain', resolve));
    chunks = []; size = 0; oversized = false;
  }
  for await (const chunk of input) {
    const bytes = Buffer.from(chunk);
    let start = 0;
    for (let i = 0; i <= bytes.length; i++) {
      if (i !== bytes.length && bytes[i] !== 10) continue;
      const part = bytes.subarray(start, i);
      size += part.length;
      if (size > MAX_LINE) { oversized = true; chunks = []; }
      else if (!oversized) chunks.push(part);
      if (i < bytes.length) await finish();
      start = i + 1;
    }
  }
  if (size || oversized) await finish();
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const worker = createWorker();
  try { await runProtocol(process.stdin, process.stdout, worker); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
  finally { await worker.close(); }
}
