import { handleMessage } from "./protocol.js";

// Keep one native process for the acknowledged stream, rather than launching a
// process for every 64 KiB slice. No payload is retained after its response.
const NATIVE_APP = "com.hildgyorgy.dropviewrender";
let port;
const pending = new Map();
function sendNative(_app, request) {
  return new Promise((resolve, reject) => {
    if (pending.size >= 4) { reject(new Error("Native request limit")); return; }
    if (!port) {
      port = chrome.runtime.connectNative(NATIVE_APP);
      port.onMessage.addListener(reply => {
        const entry = pending.get(reply?.id);
        if (!entry) return;
        pending.delete(reply.id);
        clearTimeout(entry.timer);
        entry.resolve(reply);
      });
      port.onDisconnect.addListener(() => {
        const reason = chrome.runtime.lastError?.message ?? "Native host disconnected";
        port = null;
        for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(new Error(reason)); }
        pending.clear();
      });
    }
    const timer = setTimeout(() => {
      pending.delete(request.id);
      reject(new Error("Native request timed out"));
    }, request.operation === "pair" ? 120000 : request.operation === "uploadFinish" ? 600000 : 15000);
    pending.set(request.id, { resolve, reject, timer });
    try { port.postMessage(request); }
    catch (error) { clearTimeout(timer); pending.delete(request.id); reject(error); }
  });
}
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handleMessage(message, sender, sendNative, "chromium-native-messaging").then(sendResponse,
    () => sendResponse({ protocolVersion: 1, id: message?.id ?? "", ok: false, error: "native_unavailable" }));
  return true;
});
