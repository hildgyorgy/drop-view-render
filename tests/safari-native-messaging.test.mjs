import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import vm from "node:vm";
import { webcrypto } from "node:crypto";
import { allowedPage, handleMessage, NATIVE_APP } from "../DropViewRender/SafariExtension/Resources/protocol.js";
import { SafariRenderBridgeClient } from "../../drop-3d-view/js/core/safari-render-bridge.js";

const content = readFileSync(new URL("../DropViewRender/SafariExtension/Resources/content.js", import.meta.url), "utf8");
const sender = { tab: { id: 1 }, frameId: 0, url: "http://127.0.0.1:4173/" };
const ping = () => ({ protocolVersion: 1, operation: "ping", id: webcrypto.randomUUID(), text: "Árvíztűrő 🪟" });

function native(app, request) {
  assert.equal(app, NATIVE_APP);
  const run = spawnSync(process.env.DVR_NATIVE_SMOKE || "/tmp/dvr-safari-native-smoke", ["--stdio"], {
    input: JSON.stringify(request), encoding: "utf8", timeout: 5000
  });
  assert.equal(run.status, 0, run.error?.message || run.stderr);
  return JSON.parse(run.stdout);
}

class PageWindow {
  location = { origin: "http://127.0.0.1:4173" };
  top = this;
  listeners = new Set();
  addEventListener(_, listener) { this.listeners.add(listener); }
  removeEventListener(_, listener) { this.listeners.delete(listener); }
  postMessage(data, origin) {
    assert.equal(origin, this.location.origin);
    queueMicrotask(() => this.deliver({ data, origin, source: this }));
  }
  deliver(event) { for (const receive of [...this.listeners]) void receive(event); }
}

test("production page client -> content -> background protocol -> real Swift NSExtension handler -> pong", async () => {
  const page = new PageWindow();
  let calls = 0;
  vm.runInNewContext(content, { window: page, TextEncoder, setTimeout, clearTimeout,
    browser: { runtime: { sendMessage: message => {
      calls++;
      return handleMessage(message, sender, native);
    } } }
  });
  const client = new SafariRenderBridgeClient(page, 1500);
  const result = await client.ping("Native Swift round-trip: Árvíztűrő 🪟");
  assert.equal(result.operation, "pong");
  assert.equal(result.responder, "SafariWebExtensionHandler");
  assert.equal(result.nativeBundleIdentifier, "test-harness");
  assert.ok(result.nativeProcessID > 0);
  assert.equal(calls, 1);
  assert.equal(page.listeners.size, 1, "Only the content listener remains");
  assert.equal(client.busy, false);
});

test("content ignores other windows/origins, oversize text and unsupported operations", async () => {
  const page = new PageWindow();
  let calls = 0;
  vm.runInNewContext(content, { window: page, TextEncoder, setTimeout, clearTimeout,
    browser: { runtime: { sendMessage: () => { calls++; } } }
  });
  const event = { source: page, origin: page.location.origin,
    data: { channel: "drop-view-render:safari:request", message: ping() } };
  page.deliver({ ...event, source: {} });
  page.deliver({ ...event, origin: "https://evil.example" });
  for (const override of [{ text: "x".repeat(1025) }, { operation: "render" }, { id: "invalid" }]) {
    page.deliver({ ...event, data: { ...event.data, message: { ...ping(), ...override } } });
  }
  assert.equal(calls, 0);
});

test("background derives URL from Safari sender, strips extra fields, rejects iframes and bad replies", async () => {
  for (const badSender of [{ ...sender, frameId: 1 }, { ...sender, tab: undefined },
    { ...sender, url: "https://hildgyorgy.github.io/other-project/" },
    { ...sender, url: "http://127.0.0.1.evil.example/" }]) {
    assert.equal((await handleMessage(ping(), badSender, () => assert.fail())).error, "origin_not_allowed");
  }
  const request = ping();
  const result = await handleMessage({ ...request, pageURL: "https://evil.example", extra: "x".repeat(10000) },
    sender, (app, data) => {
      assert.equal(data.pageURL, sender.url);
      assert.equal(data.extra, undefined);
      return native(app, data);
    });
  assert.equal(result.ok, true);
  assert.equal((await handleMessage(request, sender, () => ({ id: "wrong" }))).error, "invalid_native_response");
  assert.equal((await handleMessage(request, sender, () => { throw new Error(); })).error, "native_unavailable");
  assert.equal(allowedPage("https://hildgyorgy.github.io/drop-3d-view/"), true);
  assert.equal(allowedPage("https://hildgyorgy.github.io/drop-3d-view-evil/"), false);
});

test("missing extension times out, ignores spoofed replies and releases listener/busy state", async () => {
  const page = new PageWindow();
  const client = new SafariRenderBridgeClient(page, 20);
  const result = client.ping();
  page.deliver({ source: {}, origin: page.location.origin,
    data: { channel: "drop-view-render:safari:response", message: { id: "wrong" } } });
  await assert.rejects(client.ping(), /already running/);
  await assert.rejects(result, /No browser extension response/);
  assert.equal(client.busy, false);
  assert.equal(page.listeners.size, 0);
});
