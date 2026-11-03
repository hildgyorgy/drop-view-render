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
    if (!request || request.protocolVersion !== 1 || request.operation !== "ping" ||
        typeof request.id !== "string" || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(request.id) ||
        typeof request.text !== "string" || new TextEncoder().encode(request.text).length > 1024 ||
        pending >= 4 || active.has(request.id)) return;
    pending++;
    active.add(request.id);
    let message;
    let timeout;
    const timer = new Promise(resolve => { timeout = setTimeout(() => resolve({
      protocolVersion: 1, id: request.id, ok: false, error: "native_timeout"
    }), 8000); });
    try {
      // Copy only the small protocol fields; never serialize page-supplied blobs.
      message = await Promise.race([browser.runtime.sendMessage({
        protocolVersion: 1, id: request.id, operation: "ping", text: request.text
      }), timer]);
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
