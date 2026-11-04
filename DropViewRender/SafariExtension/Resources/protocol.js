export const NATIVE_APP = "com.hildgyorgy.DropViewRender";

export function allowedPage(value) {
  try {
    const url = new URL(value);
    if (url.username || url.password) return false;
    return (url.origin === "https://hildgyorgy.github.io" &&
      (url.pathname === "/drop-3d-view" || url.pathname.startsWith("/drop-3d-view/"))) ||
      (url.protocol === "http:" && ["localhost", "127.0.0.1"].includes(url.hostname));
  } catch { return false; }
}

export function validPing(value) {
  return value && typeof value === "object" && !Array.isArray(value) &&
    value.protocolVersion === 1 && value.operation === "ping" &&
    typeof value.id === "string" && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value.id) &&
    typeof value.text === "string" && new TextEncoder().encode(value.text).length <= 1024;
}

export function failure(id, error) {
  return { protocolVersion: 1, id, ok: false, error };
}

const uuid = value => typeof value === "string" && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
export function sanitizeRequest(value) {
  if (!value || typeof value !== "object" || Array.isArray(value) || value.protocolVersion !== 1 || !uuid(value.id)) return null;
  const { id, operation } = value;
  const request = { protocolVersion: 1, id, operation };
  if (operation === "ping") return validPing(value) ? { ...request, text: value.text } : null;
  if (operation === "pair") return request;
  if (typeof value.token !== "string" || !/^[A-Fa-f0-9-]{72}$/.test(value.token)) return null;
  request.token = value.token;
  if (["status", "disconnect"].includes(operation)) return request;
  if (["job", "cancel", "reveal"].includes(operation))
    return uuid(value.jobID) ? { ...request, jobID: value.jobID } : null;
  if (operation === "uploadBegin")
    return uuid(value.key) && Number.isSafeInteger(value.totalBytes) && value.totalBytes >= 24 && value.totalBytes <= 2 ** 31
      ? { ...request, key: value.key, totalBytes: value.totalBytes } : null;
  if (!uuid(value.uploadID)) return null;
  request.uploadID = value.uploadID;
  if (["uploadFinish", "uploadAbort"].includes(operation)) return request;
  if (operation === "uploadChunk" && Number.isSafeInteger(value.offset) && value.offset >= 0 && value.offset < 2 ** 31 &&
      typeof value.base64 === "string" && value.base64.length > 0 && value.base64.length <= 87384 &&
      /^[A-Za-z0-9+/]*={0,2}$/.test(value.base64) &&
      typeof value.digest === "string" && /^[a-f0-9]{64}$/.test(value.digest)) {
    return { ...request, offset: value.offset, base64: value.base64, digest: value.digest };
  }
  return null;
}

export async function handleMessage(message, sender, sendNative) {
  if (!sender.tab || sender.frameId !== 0 || !allowedPage(sender.url)) {
    return failure("", "origin_not_allowed");
  }
  const request = sanitizeRequest(message);
  if (!request) return failure(uuid(message?.id) ? message.id : "", "invalid_message");
  request.pageURL = sender.url;
  try {
    const result = await sendNative(NATIVE_APP, request);
    if (!result || result.protocolVersion !== 1 || result.id !== request.id ||
        typeof result.ok !== "boolean" ||
        (result.ok && (result.transport !== "safari-native-messaging" ||
          (request.operation === "ping" ? result.operation !== "pong" || result.text !== request.text ||
            result.app !== "Drop & View Render" : !result.data || typeof result.data !== "object")))) {
      return failure(request.id, "invalid_native_response");
    }
    return result;
  } catch { return failure(request.id, "native_unavailable"); }
}
