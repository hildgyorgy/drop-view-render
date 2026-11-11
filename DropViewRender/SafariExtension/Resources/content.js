// Isolated extension world; this is the only page -> extension entry point.
(() => {
  if (window.top !== window || window.location.origin === "null") return;
  const origin = window.location.origin;
  let pending = 0;
  const active = new Set();
  window.addEventListener("message", async event => {
    if (event.source !== window || event.origin !== origin ||
        event.data?.channel !== "drop-view-render:safari:request") return;
    const request = event.data.message;
    if (!request || request.protocolVersion !== 1 ||
        !["discover", "ping", "pair", "status", "disconnect", "job", "cancel", "reveal",
          "uploadBegin", "uploadChunk", "uploadFinish", "uploadAbort"].includes(request.operation) ||
        typeof request.id !== "string" || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(request.id) ||
        pending >= 4 || active.has(request.id)) return;
    // A strict bounded copy prevents a page's Blob/extra fields crossing IPC.
    const copy = { protocolVersion: 1, id: request.id, operation: request.operation };
    for (const [key, max] of Object.entries({ text: 1024, token: 72, jobID: 36, key: 36, uploadID: 36,
      base64: 87384, digest: 64 })) {
      if (request[key] !== undefined) {
        if (typeof request[key] !== "string" || request[key].length > max ||
            (key === "text" && new TextEncoder().encode(request[key]).length > max)) return;
        copy[key] = request[key];
      }
    }
    if (request.operation === "ping" && typeof copy.text !== "string") return;
    if (request.operation === "uploadBegin") for (const key of ["denoise", "adaptive"]) {
      if (request[key] !== undefined) {
        if (typeof request[key] !== "boolean") return;
        copy[key] = request[key];
      }
    }
    for (const key of ["offset", "totalBytes"]) if (request[key] !== undefined) {
      if (!Number.isSafeInteger(request[key]) || request[key] < 0 || request[key] > 2 ** 31) return;
      copy[key] = request[key];
    }
    pending++;
    active.add(request.id);
    let message;
    let timeout;
    const timer = new Promise(resolve => { timeout = setTimeout(() => resolve({
      protocolVersion: 1, id: request.id, ok: false, error: "native_timeout"
    }), request.operation === "pair" ? 120000 : request.operation === "uploadFinish" ? 600000 : 15000); });
    try {
      // Copy only the small protocol fields; never serialize page-supplied blobs.
      message = await Promise.race([(globalThis.browser ?? globalThis.chrome).runtime.sendMessage(copy), timer]);
    } catch {
      message = { protocolVersion: 1, id: request.id, ok: false, error: "extension_unavailable" };
    } finally {
      clearTimeout(timeout);
      active.delete(request.id);
      pending--;
    }
    window.postMessage({ channel: "drop-view-render:safari:response", message }, origin);
  });
})();
