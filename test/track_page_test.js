const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { runInNewContext } = require('node:vm');
const { resolve } = require('node:path');

const template = readFileSync(resolve(__dirname, '../track.erb'), 'utf8');
const pageScript = template.match(/<script type="text\/javascript">([\s\S]*?)<\/script>/)[1]
  .replace(/<%= track_id %>/g, 'AAAAAAAAAAAAAAAA');
const downloader = readFileSync(resolve(__dirname, '../audio-download.js'), 'utf8');

function openTrackPage({ failMetadata = false } = {}) {
  const requests = [];
  const errors = [];
  const elements = new Map();
  const document = {
    getElementById(id) {
      if (!elements.has(id)) { elements.set(id, { value: '' }); }
      return elements.get(id);
    }
  };
  const audio = new EventTarget();
  audio.pause = () => {};
  audio.load = () => {};
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
      click() { return selection; }
    };
    return selection;
  }
  $.each = (values, callback) => values.forEach((value, index) => callback(index, value));

  const context = {
    $, window, document, AbortController, DOMException, setTimeout,
    console: { error: error => errors.push(error) },
    fetch(url, { signal }) {
      requests.push(url);
      return new Promise((resolve, reject) => {
        signal.addEventListener('abort', () => reject(new DOMException('Cancelled', 'AbortError')), { once: true });
      });
    }
  };
  runInNewContext(downloader, context);
  runInNewContext(pageScript, context);
  return { requests, errors, elements, window };
}

test('opening the track page starts an audio request with the existing jQuery version', async () => {
  const page = openTrackPage();
  try {
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(page.requests, ['/audio/AAAAAAAAAAAAAAAA'],
      'the page must call fetch instead of remaining at Downloading audio with no network request');
    assert.deepEqual(page.errors, []);
  } finally {
    page.window.dispatchEvent(new Event('pagehide'));
  }
});

test('unexpected startup errors replace the downloading message with an explanation', async () => {
  const page = openTrackPage({ failMetadata: true });
  await new Promise(resolve => setImmediate(resolve));
  assert.match(page.elements.get('audio-status').textContent,
    /Unable to initialize track: Metadata setup failed/);
  assert.equal(page.errors.length, 1);
});
