import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable, Writable } from 'node:stream';
import sharp from 'sharp';
import { Gemma4ImageProcessor, Gemma4AudioFeatureExtractor } from '@huggingface/transformers';
import { validateRequest, validateSession, decodeImage, decodeAudio, createWorker, runProtocol, MAX_LINE } from './media_worker.mjs';

test('request validation rejects URLs, relative paths and invalid offsets', () => {
  for (const path of ['https://example.com/a', 'file:///tmp/a', 'relative']) assert.throws(() => validateRequest({ kind: 'image', path }));
  for (const offset of [-1, NaN, Infinity, '0']) assert.throws(() => validateRequest({ kind: 'audio', path: '/tmp/a', offset }));
  assert.equal(validateRequest({ kind: 'audio', path: '/tmp/a' }).offset, 0);
});

test('bounded JSON lines recover after malformed and oversized requests; sequential dispatch', async () => {
  let result = '', active = 0;
  const output = new Writable({ write(chunk, encoding, callback) { result += chunk; callback(); } });
  const worker = { async handle(input) { assert.equal(active++, 0); await new Promise(resolve => setTimeout(resolve, 2)); active--; return { features: [], tokens: input.tokens }; } };
  await runProtocol(Readable.from([Buffer.from('bad\n' + 'x'.repeat(MAX_LINE + 1)), Buffer.from('\n{"tokens":1}\n{"tokens":2}')]), output, worker);
  const responses = result.trim().split('\n').map(JSON.parse);
  assert.equal(responses.length, 4);
  assert.match(responses[0].error, /JSON/);
  assert.match(responses[1].error, /limit/);
  assert.deepEqual(responses.slice(2).map(x => x.tokens), [1, 2]);
});

test('metadata must match native encoder names, types and widths', () => {
  const session = {
    inputNames: ['pixel_values', 'pixel_position_ids'], outputNames: ['image_features'],
    inputMetadata: [
      { isTensor: true, type: 'float32', shape: ['n', 2520, 768] },
      { isTensor: true, type: 'int64', shape: ['n', 2520, 2] },
    ], outputMetadata: [{ isTensor: true, type: 'float32', shape: ['real', 512] }],
  };
  validateSession(session, 'image');
  session.outputMetadata[0].shape[1] = 513;
  assert.throws(() => validateSession(session, 'image'));
});

test('local decoding, image patch order, exact Gemma4 logmel/mask, invalid media and empty audio', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'nrc-media-'));
  try {
    const imagePath = join(dir, 'image.png');
    await sharp({ create: { width: 48, height: 48, channels: 3, background: { r: 255, g: 0, b: 0 } } }).png().toFile(imagePath);
    const image = await decodeImage(imagePath);
    const prepared = await new Gemma4ImageProcessor({})([image]);
    assert.deepEqual(prepared.pixel_values.dims, [1, 2520, 768]);
    assert.deepEqual(prepared.image_position_ids.dims, [1, 2520, 2]);
    assert.deepEqual(Array.from(prepared.pixel_values.data.slice(0, 6)), [1, 0, 0, 1, 0, 0]);
    assert.equal(prepared.num_soft_tokens_per_image[0], 256);
    const extractor = new Gemma4AudioFeatureExtractor({ sampling_rate: 16000, feature_size: 128,
      frame_length: 320, hop_length: 160, fft_length: 512, min_frequency: 0, max_frequency: 8000,
      preemphasis: 0.97, preemphasis_htk_flavor: true, mel_floor: 1e-5, padding_value: 0 });
    const audio = new Float32Array(16000);
    const a = await extractor(audio), b = await extractor(audio);
    assert.deepEqual(a.input_features.dims, [1, 99, 128]);
    assert.deepEqual(a.input_features.data, b.input_features.data);
    assert.ok(a.input_features.data.every(Number.isFinite));
    assert.equal(a.input_features_mask.data.reduce((sum, x) => sum + x, 0), 99);
    assert.ok(Math.abs(a.input_features.data[0] - Math.log(1e-5)) < 1e-5);
    const wav = Buffer.alloc(44 + 16000 * 2);
    wav.write('RIFF'); wav.writeUInt32LE(wav.length - 8, 4); wav.write('WAVEfmt ', 8);
    wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22);
    wav.writeUInt32LE(16000, 24); wav.writeUInt32LE(32000, 28); wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34);
    wav.write('data', 36); wav.writeUInt32LE(wav.length - 44, 40);
    const audioPath = join(dir, 'audio.wav'); await writeFile(audioPath, wav);
    assert.equal((await decodeAudio(audioPath)).length, 16000);
    assert.equal((await decodeAudio(audioPath, 2)).length, 0);
    const playlist = join(dir, 'playlist');
    await writeFile(playlist, `ffconcat version 1.0\nfile '${audioPath}'\n`);
    await assert.rejects(() => decodeAudio(playlist), /invalid audio/);
    const worker = createWorker();
    assert.deepEqual(await worker.handle({ kind: 'audio', path: audioPath, offset: 2 }), { features: [], tokens: 0 });
    const bad = join(dir, 'bad'); await writeFile(bad, 'not media');
    assert.ok((await worker.handle({ kind: 'image', path: bad })).error);
    assert.match((await worker.handle({ kind: 'audio', path: bad })).error, /invalid audio/);
    await worker.close();
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('real pinned encoder smoke tests (opt-in)', { skip: !process.env.MEDIA_MODEL_DIR }, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'nrc-media-model-'));
  const worker = createWorker();
  try {
    const path = join(dir, 'image.png');
    await sharp({ create: { width: 48, height: 48, channels: 3, background: 'red' } }).png().toFile(path);
    const result = await worker.handle({ kind: 'image', path });
    assert.equal(result.error, undefined);
    assert.equal(result.features.length, result.tokens * 512);
    assert.ok(result.tokens > 0);
    const wav = Buffer.alloc(44 + 32000);
    wav.write('RIFF'); wav.writeUInt32LE(wav.length - 8, 4); wav.write('WAVEfmt ', 8);
    wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22);
    wav.writeUInt32LE(16000, 24); wav.writeUInt32LE(32000, 28); wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34);
    wav.write('data', 36); wav.writeUInt32LE(32000, 40);
    const audioPath = join(dir, 'audio.wav'); await writeFile(audioPath, wav);
    const audio = await worker.handle({ kind: 'audio', path: audioPath });
    assert.equal(audio.error, undefined);
    assert.equal(audio.features.length, audio.tokens * 512);
    assert.ok(audio.tokens > 0);
  } finally { await worker.close(); await rm(dir, { recursive: true, force: true }); }
});
