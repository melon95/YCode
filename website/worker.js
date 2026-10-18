// Static assets don't answer HTTP Range requests, which browsers need to seek
// video. wrangler.jsonc routes only /assets/*.mp4 through this Worker; it
// slices the asset into a 206 response. Everything else is served as-is.
export default {
  async fetch(request, env) {
    // Ask for the plain file so byte offsets are never applied to a compressed body.
    const asset = await env.ASSETS.fetch(new Request(request.url, { method: request.method }));
    if (asset.status !== 200) return asset;

    const headers = new Headers(asset.headers);
    headers.set('Accept-Ranges', 'bytes');
    headers.delete('Content-Encoding');

    // Range only applies to GET. HEAD must retain the full asset metadata.
    if (request.method !== 'GET') return new Response(asset.body, { status: 200, headers });

    const validator = request.headers.get('If-Range');
    if (validator) {
      const etag = headers.get('ETag');
      const modified = headers.get('Last-Modified');
      // Weak validators do not authorize a partial response. Date validators
      // must exactly match the asset's Last-Modified representation.
      const matches = validator.startsWith('"')
        ? validator === etag && !validator.startsWith('W/')
        : !validator.startsWith('W/') && modified !== null && validator === modified;
      if (!matches) return new Response(asset.body, { status: 200, headers });
    }

    const range = request.headers.get('Range');
    const match = range && /^bytes=(\d*)-(\d*)$/.exec(range.trim());
    if (!match || (match[1] === '' && match[2] === '')) {
      return new Response(asset.body, { status: 200, headers });
    }

    const body = await asset.arrayBuffer();
    const size = body.byteLength;
    let start;
    let end;
    if (match[1] === '') {
      // Suffix range: the last N bytes.
      start = Math.max(0, size - Number(match[2]));
      end = size - 1;
    } else {
      start = Number(match[1]);
      end = match[2] === '' ? size - 1 : Math.min(Number(match[2]), size - 1);
    }
    if (start >= size || start > end) {
      return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
    }

    headers.set('Content-Range', `bytes ${start}-${end}/${size}`);
    headers.set('Content-Length', String(end - start + 1));
    return new Response(request.method === 'HEAD' ? null : body.slice(start, end + 1), { status: 206, headers });
  },
};
