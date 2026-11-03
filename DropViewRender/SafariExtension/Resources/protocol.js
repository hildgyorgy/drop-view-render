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

export async function handleMessage(message, sender, sendNative) {
  if (!sender.tab || sender.frameId !== 0 || !allowedPage(sender.url)) {
    return failure("", "origin_not_allowed");
  }
  if (!validPing(message)) return failure("", "invalid_message");
  const request = {
    protocolVersion: 1, id: message.id, operation: "ping", text: message.text,
    pageURL: sender.url
  };
  try {
    const result = await sendNative(NATIVE_APP, request);
    if (!result || result.protocolVersion !== 1 || result.id !== request.id ||
        typeof result.ok !== "boolean" ||
        (result.ok && (result.operation !== "pong" || result.text !== request.text ||
          result.app !== "Drop & View Render" || result.transport !== "safari-native-messaging"))) {
      return failure(request.id, "invalid_native_response");
    }
    return result;
  } catch { return failure(request.id, "native_unavailable"); }
}
