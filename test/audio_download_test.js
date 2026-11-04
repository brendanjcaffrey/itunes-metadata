const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { runInNewContext } = require('node:vm');
const { resolve } = require('node:path');

const source = readFileSync(resolve(__dirname, '../audio-download.js'), 'utf8');
const flush = () => new Promise(resolve => setImmediate(resolve));

function setup(fetch, globals = {}) {
  const window = new EventTarget();
  const audio = new EventTarget();
  const revoked = [];
  const blobs = [];
  audio.pause = () => {};
  audio.removeAttribute = name => { delete audio[name]; };
  audio.load = () => {};
  const context = {
    window, fetch, AbortController, DOMException, Blob,
    URL: {
      createObjectURL(blob) { blobs.push(blob); return 'blob:local-audio'; },
      revokeObjectURL(url) { revoked.push(url); }
    },
    ...globals
  };
  runInNewContext(source, context);
  return { ...context, audio, revoked, blobs };
}

test('MP3 playback uses decoded PCM so seeks do not rely on the MP3 seek table', async () => {
  const channels = [new Float32Array([0, 0.5, -0.5, 1]), new Float32Array([0, -0.5, 0.5, -1])];
  let decodedInput;
  class Decoder {
    async decodeAudioData(input) {
      decodedInput = input;
      return { numberOfChannels: 2, length: 4, sampleRate: 48000, getChannelData: channel => channels[channel] };
    }
  }
  const mp3 = new Blob(['original mp3'], { type: 'audio/mpeg' });
  const fixture = setup(async () => ({ ok: true, blob: async () => mp3 }), { OfflineAudioContext: Decoder });
  const loading = fixture.downloadTrackAudio(fixture.audio, '/audio/id');
  try {
    await flush();
    assert.equal(fixture.blobs[0].type, 'audio/wav', 'native MP3 seeking can play the wrong section in Firefox');
    assert.equal(new TextDecoder().decode(decodedInput), 'original mp3');
    const bytes = new DataView(await fixture.blobs[0].arrayBuffer());
    assert.equal(bytes.getUint32(0, true), 0x46464952); // RIFF
    assert.equal(bytes.getUint16(20, true), 1); // PCM
    assert.equal(bytes.getUint16(22, true), 2); // stereo
    assert.equal(bytes.getUint32(24, true), 48000);
    assert.equal(bytes.getUint16(34, true), 16);
    assert.equal(bytes.getUint32(40, true), 16);
    assert.equal(bytes.byteLength, 60);
    assert.deepEqual(Array.from({ length: 8 }, (_, index) => bytes.getInt16(44 + index * 2, true)),
      [0, 0, 16384, -16384, -16384, 16384, 32767, -32768]);
  } finally {
    fixture.audio.dispatchEvent(new Event('loadedmetadata'));
    await loading;
  }
});

test('waits for the complete response before assigning a local playback source', async () => {
  let finishDownload;
  let requests = 0;
  const fixture = setup(async (url, options) => {
    requests++;
    assert.equal(url, '/audio/track-id');
    assert.equal(options.cache, 'no-store');
    return { ok: true, blob: () => new Promise(resolve => { finishDownload = resolve; }) };
  });
  let ready = false;
  const loading = fixture.downloadTrackAudio(fixture.audio, '/audio/track-id').then(() => { ready = true; });
  await flush();
  assert.equal(fixture.audio.src, undefined, 'partial downloads must not reach the media element');
  const completeFile = new Blob(['complete audio'], { type: 'audio/wav' });
  finishDownload(completeFile);
  await flush();
  assert.equal(fixture.audio.src, 'blob:local-audio');
  assert.equal(fixture.blobs[0], completeFile);
  assert.equal(ready, false, 'the player must also wait for audio metadata');
  fixture.audio.dispatchEvent(new Event('loadedmetadata'));
  await loading;
  assert.equal(ready, true);
  fixture.audio.currentTime = 42;
  assert.equal(requests, 1, 'seeking uses the blob, with no additional network request');
});

test('rejects HTTP errors without assigning an audio source', async () => {
  const fixture = setup(async () => ({ ok: false, status: 503 }));
  await assert.rejects(fixture.downloadTrackAudio(fixture.audio, '/audio/id'), /HTTP 503/);
  assert.equal(fixture.audio.src, undefined);
  assert.equal(fixture.blobs.length, 0);
});

test('rejects incomplete response downloads', async () => {
  const fixture = setup(async () => ({ ok: true, blob: async () => { throw new Error('Connection lost'); } }));
  await assert.rejects(fixture.downloadTrackAudio(fixture.audio, '/audio/id'), /Connection lost/);
  assert.equal(fixture.audio.src, undefined);
  assert.equal(fixture.blobs.length, 0);
});

test('rejects an empty audio file', async () => {
  const fixture = setup(async () => ({ ok: true, blob: async () => new Blob([]) }));
  await assert.rejects(fixture.downloadTrackAudio(fixture.audio, '/audio/id'), /empty/);
  assert.equal(fixture.blobs.length, 0);
});

test('releases a failed media source and permits a fresh download attempt', async () => {
  const fixture = setup(async () => ({ ok: true, blob: async () => new Blob(['mp3']) }));
  let loading = fixture.downloadTrackAudio(fixture.audio, '/audio/id');
  const failed = assert.rejects(loading, /could not load/);
  await flush();
  fixture.audio.dispatchEvent(new Event('error'));
  await failed;
  assert.deepEqual(fixture.revoked, ['blob:local-audio']);
  assert.equal(fixture.audio.src, undefined);

  loading = fixture.downloadTrackAudio(fixture.audio, '/audio/id');
  await flush();
  fixture.audio.dispatchEvent(new Event('loadedmetadata'));
  await loading;
  assert.equal(fixture.audio.src, 'blob:local-audio');
});

test('preserves cached-page playback and revokes the blob when leaving permanently', async () => {
  const fixture = setup(async () => ({ ok: true, blob: async () => new Blob(['mp3']) }));
  const loading = fixture.downloadTrackAudio(fixture.audio, '/audio/id');
  await flush();
  fixture.audio.dispatchEvent(new Event('loadedmetadata'));
  await loading;
  const cachedPageHide = new Event('pagehide');
  cachedPageHide.persisted = true;
  fixture.window.dispatchEvent(cachedPageHide);
  assert.equal(fixture.audio.src, 'blob:local-audio');
  assert.deepEqual(fixture.revoked, []);
  fixture.window.dispatchEvent(new Event('pagehide'));
  assert.deepEqual(fixture.revoked, ['blob:local-audio']);
  assert.equal(fixture.audio.src, undefined);
});

test('cancels an unfinished download when navigating away', async () => {
  const fixture = setup((url, { signal }) => new Promise((resolve, reject) => {
    signal.addEventListener('abort', () => reject(new DOMException('Cancelled', 'AbortError')), { once: true });
  }));
  const loading = fixture.downloadTrackAudio(fixture.audio, '/audio/id');
  const cancelled = assert.rejects(loading, { name: 'AbortError' });
  fixture.window.dispatchEvent(new Event('pagehide'));
  await cancelled;
  assert.equal(fixture.blobs.length, 0);
});

test('switching formats during MP3 decoding cannot replace or release the newer WAV source', async () => {
  let finishDecoding;
  class Decoder {
    decodeAudioData() { return new Promise(resolve => { finishDecoding = resolve; }); }
  }
  const fixture = setup(async url => ({
    ok: true,
    blob: async () => new Blob(['audio'], { type: url.endsWith('mp3') ? 'audio/mpeg' : 'audio/wav' })
  }), { OfflineAudioContext: Decoder });
  const controller = new AbortController();
  const first = fixture.downloadTrackAudio(fixture.audio, '/audio/id?format=mp3', controller.signal);
  const cancelled = assert.rejects(first, { name: 'AbortError' });
  await flush();
  controller.abort();
  const second = fixture.downloadTrackAudio(fixture.audio, '/audio/id?format=wav');
  await flush();
  fixture.audio.dispatchEvent(new Event('loadedmetadata'));
  const release = await second;
  finishDecoding({});
  await cancelled;
  assert.equal(fixture.audio.src, 'blob:local-audio');
  assert.equal(fixture.blobs.length, 1);
  assert.deepEqual(fixture.revoked, []);
  release();
  release();
  assert.deepEqual(fixture.revoked, ['blob:local-audio'], 'releasing a source is idempotent');
});
