// Native VBR MP3 seeks can land on the wrong audio in Firefox. Decode the full
// download once and give the media element a local PCM WAV with exact offsets.
function pcmWaveBlob(buffer) {
  const channels = buffer.numberOfChannels;
  const blockSize = channels * 2;
  const dataSize = buffer.length * blockSize;
  const bytes = new ArrayBuffer(44 + dataSize);
  const view = new DataView(bytes);
  view.setUint32(0, 0x46464952, true); // RIFF
  view.setUint32(4, 36 + dataSize, true);
  view.setUint32(8, 0x45564157, true); // WAVE
  view.setUint32(12, 0x20746d66, true); // fmt
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, channels, true);
  view.setUint32(24, buffer.sampleRate, true);
  view.setUint32(28, buffer.sampleRate * blockSize, true);
  view.setUint16(32, blockSize, true);
  view.setUint16(34, 16, true);
  view.setUint32(36, 0x61746164, true); // data
  view.setUint32(40, dataSize, true);
  const samples = Array.from({ length: channels }, (_, channel) => buffer.getChannelData(channel));
  let offset = 44;
  for (let frame = 0; frame < buffer.length; frame++) {
    for (let channel = 0; channel < channels; channel++) {
      const sample = Math.max(-1, Math.min(1, samples[channel][frame]));
      view.setInt16(offset, Math.round(sample * (sample < 0 ? 32768 : 32767)), true);
      offset += 2;
    }
  }
  return new Blob([bytes], { type: 'audio/wav' });
}

// Fetch the entire file before assigning a source to the media element. A blob
// URL keeps subsequent playback and seeks local, independent of network speed.
async function downloadTrackAudio(audio, sourceUrl) {
  const controller = new AbortController();
  let objectUrl;
  let released = false;

  function release() {
    if (released) { return; }
    released = true;
    controller.abort();
    window.removeEventListener('pagehide', onPageHide);
    audio.pause();
    audio.removeAttribute('src');
    audio.load();
    if (objectUrl) { URL.revokeObjectURL(objectUrl); }
  }

  function onPageHide(event) {
    // Keep the local source when the browser preserves this page for Back.
    if (event.persisted) { audio.pause(); }
    else { release(); }
  }

  window.addEventListener('pagehide', onPageHide);
  try {
    const response = await fetch(sourceUrl, { signal: controller.signal, cache: 'no-store' });
    if (!response.ok) { throw new Error(`HTTP ${response.status}`); }
    let blob = await response.blob();
    if (controller.signal.aborted) { throw new DOMException('Download cancelled', 'AbortError'); }
    if (!blob.size) { throw new Error('The audio file is empty'); }

    if (/^audio\/(mpeg|mp3)(;|$)/.test(blob.type)) {
      // Offline decoding needs no autoplay permission. 48 kHz preserves the
      // frequency range of all MP3 sample rates, including 44.1 and 48 kHz.
      const decoder = new OfflineAudioContext(2, 1, 48000);
      const decoded = await decoder.decodeAudioData(await blob.arrayBuffer());
      if (controller.signal.aborted) { throw new DOMException('Download cancelled', 'AbortError'); }
      blob = pcmWaveBlob(decoded);
    }

    objectUrl = URL.createObjectURL(blob);
    const ready = new Promise((resolve, reject) => {
      function cleanup() {
        audio.removeEventListener('loadedmetadata', onReady);
        audio.removeEventListener('error', onError);
        controller.signal.removeEventListener('abort', onAbort);
      }
      function onReady() { cleanup(); resolve(); }
      function onError() { cleanup(); reject(new Error('The browser could not load this audio file')); }
      function onAbort() { cleanup(); reject(new DOMException('Download cancelled', 'AbortError')); }
      audio.addEventListener('loadedmetadata', onReady);
      audio.addEventListener('error', onError);
      controller.signal.addEventListener('abort', onAbort);
      audio.src = objectUrl;
      audio.load();
    });
    await ready;
  } catch (error) {
    release();
    throw error;
  }
}
