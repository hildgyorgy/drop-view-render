import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import vm from "node:vm";
import { handleMessage } from "../DropViewRender/SafariExtension/Resources/protocol.js";
import { ExtensionRenderBridgeClient } from "../../drop-3d-view/js/core/extension-render-bridge.js";

const app = process.env.DVR_CHROMIUM_APP ?? "/tmp/dvr-chromium/Build/Products/Debug/Drop & View Render.app";
const manifest = JSON.parse(readFileSync(`${app}/Contents/Resources/ChromiumExtension/manifest.json`, "utf8"));
const id = [...createHash("sha256").update(Buffer.from(manifest.key, "base64")).digest().subarray(0, 16)]
  .map(byte => String.fromCharCode(97 + (byte >> 4), 97 + (byte & 15))).join("");
const executable = `${app}/Contents/MacOS/DropViewRenderNativeHost`;
const origin = `chrome-extension://${id}/`;
const sender = { tab: { id: 1 }, frameId: 0, url: "http://127.0.0.1:4173/" };
const ping = () => ({ protocolVersion: 1, id: randomUUID(), operation: "ping", text: "Üveg 🪟", pageURL: sender.url });
function encode(message) {
  const data = Buffer.from(JSON.stringify(message));
  const size = Buffer.alloc(4); size.writeUInt32LE(data.length);
  return Buffer.concat([size, data]);
}
function decode(data) {
  const replies = [];
  for (let offset = 0; offset < data.length;) {
    const size = data.readUInt32LE(offset); offset += 4;
    assert.ok(size > 0 && size <= 100000);
    replies.push(JSON.parse(data.subarray(offset, offset + size).toString())); offset += size;
    assert.ok(offset <= data.length);
  }
  return replies;
}

test("Chromium host accepts multiple framed messages and refuses unregistered callers", () => {
  const first = ping(), second = ping();
  const result = spawnSync(executable, [origin], { input: Buffer.concat([encode(first), encode(second)]) });
  assert.equal(result.status, 0, result.stderr.toString());
  const replies = decode(result.stdout);
  assert.equal(replies.length, 2);
  for (const [index, reply] of replies.entries()) {
    assert.equal(reply.id, [first, second][index].id);
    assert.equal(reply.text, "Üveg 🪟");
    assert.equal(reply.ok, true);
    assert.equal(reply.transport, "chromium-native-messaging");
    assert.equal(reply.responder, "ChromiumNativeHost");
  }
  const denied = spawnSync(executable, ["chrome-extension://" + "a".repeat(32) + "/"], { input: encode(first) });
  assert.equal(denied.status, 1);
  assert.equal(denied.stdout.length, 0);
});

test("Chromium framing rejects oversized, truncated and malformed input", () => {
  const oversized = Buffer.alloc(4); oversized.writeUInt32LE(100001);
  for (const input of [oversized, Buffer.from([8, 0]), Buffer.from([2, 0, 0, 0, 123]), Buffer.from([1, 0, 0, 0, 123])]) {
    const result = spawnSync(executable, [origin], { input });
    assert.equal(result.status, 1);
    assert.equal(result.stdout.length, 0);
  }
  const denied = spawnSync(executable, [origin], { input: encode({ ...ping(), pageURL: "https://evil.example/" }) });
  assert.equal(decode(denied.stdout)[0].error, "origin_not_allowed");
});

test("discovery -> production Chromium background -> framed Swift host -> page", async () => {
  const native = spawn(executable, [origin], { stdio: ["pipe", "pipe", "pipe"] });
  let buffered = Buffer.alloc(0);
  const messageListeners = [], disconnectListeners = [];
  native.stdout.on("data", data => {
    buffered = Buffer.concat([buffered, data]);
    while (buffered.length >= 4 && buffered.length >= 4 + buffered.readUInt32LE(0)) {
      const size = buffered.readUInt32LE(0);
      const reply = JSON.parse(buffered.subarray(4, size + 4).toString());
      buffered = buffered.subarray(size + 4);
      for (const listener of messageListeners) listener(reply);
    }
  });
  native.on("exit", () => disconnectListeners.forEach(callback => callback()));
  let listener;
  let nativeStarts = 0;
  const runtime = {
    onMessage: { addListener(callback) { listener = callback; } },
    connectNative(name) {
      assert.equal(name, "com.hildgyorgy.dropviewrender"); nativeStarts++;
      return {
        onMessage: { addListener(callback) { messageListeners.push(callback); } },
        onDisconnect: { addListener(callback) { disconnectListeners.push(callback); } },
        postMessage(request) {
          const frame = encode(request);
          // Exercise partial reads, including a split length prefix.
          native.stdin.write(frame.subarray(0, 2)); native.stdin.write(frame.subarray(2, 11)); native.stdin.write(frame.subarray(11));
        }
      };
    }
  };
  const background = readFileSync(new URL("../DropViewRender/ChromiumExtension/background.js", import.meta.url), "utf8");
  vm.runInNewContext(background.replace(/^import .*;\n/, ""), { handleMessage, chrome: { runtime }, setTimeout, clearTimeout, Map, Error });
  class PageWindow {
    location = { origin: "http://127.0.0.1:4173" }; top = this; listeners = new Set();
    addEventListener(_, callback) { this.listeners.add(callback); }
    removeEventListener(_, callback) { this.listeners.delete(callback); }
    postMessage(data, target) {
      assert.equal(target, this.location.origin);
      queueMicrotask(() => { for (const callback of [...this.listeners]) callback({ source: this, origin: target, data }); });
    }
  }
  const page = new PageWindow();
  const content = readFileSync(new URL("../DropViewRender/SafariExtension/Resources/content.js", import.meta.url), "utf8");
  vm.runInNewContext(content, { window: page, TextEncoder, setTimeout, clearTimeout,
    chrome: { runtime: { sendMessage: request => new Promise(resolve => listener(request, sender, resolve)) } } });
  try {
    const client = new ExtensionRenderBridgeClient(page);
    assert.equal((await client.discover()).transport, "chromium-native-messaging");
    assert.equal(nativeStarts, 0, "discovery does not launch/pair the host");
    const response = await client.ping("Chromium diagnostic üveg");
    assert.equal(response.ok, true);
    assert.equal(response.responder, "ChromiumNativeHost");
    const repeated = await new Promise(resolve => listener(ping(), sender, resolve));
    assert.equal(repeated.ok, true);
    assert.equal(nativeStarts, 1, "one host serves the stream");
  } finally { native.stdin.end(); }
});
