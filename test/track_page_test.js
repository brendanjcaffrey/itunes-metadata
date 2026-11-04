const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { runInNewContext } = require('node:vm');
const { resolve } = require('node:path');

const template = readFileSync(resolve(__dirname, '../track.erb'), 'utf8');
const pageScript = template.match(/<script type="text\/javascript">([\s\S]*?)<\/script>/)[1]
  .replace(/<%= track_id %>/g, 'AAAAAAAAAAAAAAAA');
const downloader = readFileSync(resolve(__dirname, '../audio-download.js'), 'utf8');

const flush = () => new Promise(resolve => setImmediate(resolve));

function openTrackPage({ failMetadata = false, storage = new Map(), blockedStorage = false } = {}) {
  const requests = [];
  const downloads = [];
  const errors = [];
  const revoked = [];
  const elements = new Map();
  const document = {
    getElementById(id) {
      if (!elements.has(id)) { elements.set(id, Object.assign(new EventTarget(), { value: '' })); }
      return elements.get(id);
    }
  };
  const audio = new EventTarget();
  audio.currentTime = 0;
  audio.duration = 240;
  audio.playbackRate = 1;
  audio.pause = () => {};
  audio.load = () => { if (audio.src) { queueMicrotask(() => audio.dispatchEvent(new Event('loadedmetadata'))); } };
  audio.removeAttribute = name => { delete audio[name]; };
  elements.set('audio', audio);
  elements.set('audio-status', { textContent: 'Downloading audio…' });
  for (const [id, value] of Object.entries({ name: 'Track', artist: 'Artist', album: '', genre: 'House', year: '2026' })) {
    elements.set(id, { value });
  }
  const window = new EventTarget();

  function $(target) {
    if (target === document) {
      return {
        ready(callback) {
          // jQuery 3.2.1's Deferred accepts callbacks through isFunction(),
          // which recognizes [object Function], but not [object AsyncFunction].
          if (Object.prototype.toString.call(callback) === '[object Function]') { callback(); }
        }
      };
    }
    const element = typeof target === 'string' && target.startsWith('#')
      ? document.getElementById(target.slice(1)) : target;
    const selection = {
      val(value) {
        if (failMetadata) { throw new Error('Metadata setup failed'); }
        if (value === undefined) { return element.value; }
        element.value = value;
        return selection;
      },
      each() { return selection; },
      addClass() { return selection; },
      removeClass() { return selection; },
      attr() { return selection; },
      bind() { return selection; },
      click() { return selection; },
      change() { return selection; },
      prop(name, value) { element[name] = value; return selection; },
      text() { return selection; },
      resize() { return selection; },
      keypress() { return selection; },
      keydown() { return selection; },
      keyup() { return selection; }
    };
    return selection;
  }
  $.each = (values, callback) => values.forEach((value, index) => callback(index, value));

  const context = {
    $, window, document, AbortController, DOMException, setTimeout, Blob,
    localStorage: {
      getItem(key) { if (blockedStorage) { throw new Error('Storage unavailable'); } return storage.get(key); },
      setItem(key, value) { if (blockedStorage) { throw new Error('Storage unavailable'); } storage.set(key, value); }
    },
    URL: {
      createObjectURL: () => `blob:audio-${downloads.length}`,
      revokeObjectURL: url => revoked.push(url)
    },
    peaks: {
      init(options, callback) {
        const instance = { points: { getPoint: () => ({ update() {} }) }, on() {} };
        queueMicrotask(() => callback(null, instance));
        return instance;
      }
    },
    console: { error: error => errors.push(error) },
    fetch(url, { signal } = {}) {
      requests.push(url);
      if (url.startsWith('/beats/')) { return Promise.resolve({ json: async () => null }); }
      return new Promise((resolve, reject) => {
        downloads.push({ signal, resolve, reject });
        signal.addEventListener('abort', () => reject(new DOMException('Cancelled', 'AbortError')), { once: true });
      });
    }
  };
  runInNewContext(downloader, context);
  runInNewContext(pageScript, context);
  return {
    requests, downloads, errors, elements, window, revoked, audio,
    async completeDownload(index) {
      downloads[index].resolve({ ok: true, blob: async () => new Blob(['audio'], { type: 'audio/wav' }) });
      await flush();
    },
    changeFormat(value) {
      const select = document.getElementById('audio-format');
      select.value = value;
      select.dispatchEvent(new Event('change'));
    }
  };
}

test('opening the track page starts an audio request with the existing jQuery version', async () => {
  const page = openTrackPage();
  try {
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(page.requests, ['/audio/AAAAAAAAAAAAAAAA?format=wav'],
      'the page must call fetch instead of remaining at Downloading audio with no network request');
    assert.deepEqual(page.errors, []);
  } finally {
    page.window.dispatchEvent(new Event('pagehide'));
  }
});

test('saved MP3 preference is used when opening a track', () => {
  const page = openTrackPage({ storage: new Map([['audio-download-format', 'mp3']]) });
  assert.deepEqual(page.requests, ['/audio/AAAAAAAAAAAAAAAA?format=mp3']);
  assert.equal(page.elements.get('audio-format').value, 'mp3');
  page.window.dispatchEvent(new Event('pagehide'));
});

test('invalid or unavailable local storage defaults to WAV and does not block switching', async () => {
  for (const options of [{ storage: new Map([['audio-download-format', 'invalid']]) }, { blockedStorage: true }]) {
    const page = openTrackPage(options);
    assert.equal(page.elements.get('audio-format').value, 'wav');
    page.changeFormat('mp3');
    await page.completeDownload(1);
    assert.equal(page.elements.get('audio-status-row').hidden, true);
    assert.deepEqual(page.errors, []);
    page.window.dispatchEvent(new Event('pagehide'));
  }
});

test('changing format cancels an initial download and remembers the choice for the next track', async () => {
  const storage = new Map();
  const page = openTrackPage({ storage });
  page.changeFormat('mp3');
  assert.equal(page.downloads[0].signal.aborted, true);
  assert.equal(page.requests[1], '/audio/AAAAAAAAAAAAAAAA?format=mp3');
  assert.equal(storage.get('audio-download-format'), 'mp3');
  await page.completeDownload(1);
  assert.equal(page.elements.get('audio-status-row').hidden, true);
  assert.deepEqual(page.errors, []);
  page.window.dispatchEvent(new Event('pagehide'));

  const nextPage = openTrackPage({ storage });
  assert.equal(nextPage.requests[0], '/audio/AAAAAAAAAAAAAAAA?format=mp3');
  nextPage.window.dispatchEvent(new Event('pagehide'));
});

test('switching a loaded track keeps edits, playhead and speed, and supports retrying a failed download', async () => {
  const page = openTrackPage();
  await page.completeDownload(0);
  assert.equal(page.elements.get('audio-status-row').hidden, true);
  assert.equal(page.elements.get('controls button, #controls input').disabled, false);
  page.elements.get('name').value = 'Unsaved title';
  page.audio.currentTime = 42;
  page.audio.playbackRate = 1.5;
  page.changeFormat('mp3');
  assert.equal(page.elements.get('audio-status-row').hidden, false);
  assert.equal(page.elements.get('controls button, #controls input').disabled, true);
  assert.deepEqual(page.revoked, ['blob:audio-1']);
  page.downloads[1].resolve({ ok: false, status: 503 });
  await flush();
  assert.equal(page.elements.get('retry-audio').hidden, false);
  assert.match(page.elements.get('audio-status').textContent, /HTTP 503/);
  page.elements.get('retry-audio').dispatchEvent(new Event('click'));
  await page.completeDownload(2);
  assert.equal(page.audio.currentTime, 42);
  assert.equal(page.audio.playbackRate, 1.5);
  assert.equal(page.elements.get('name').value, 'Unsaved title');
  assert.equal(page.elements.get('audio-status-row').hidden, true);
  assert.equal(page.elements.get('controls button, #controls input').disabled, false);
  assert.deepEqual(page.errors, []);
  page.window.dispatchEvent(new Event('pagehide'));
});

test('unexpected startup errors replace the downloading message with an explanation', async () => {
  const page = openTrackPage({ failMetadata: true });
  await new Promise(resolve => setImmediate(resolve));
  assert.match(page.elements.get('audio-status').textContent,
    /Unable to initialize track: Metadata setup failed/);
  assert.equal(page.errors.length, 1);
});
