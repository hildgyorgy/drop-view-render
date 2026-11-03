import { handleMessage } from "./protocol.js";

browser.runtime.onMessage.addListener((message, sender) =>
  handleMessage(message, sender, (app, request) => browser.runtime.sendNativeMessage(app, request))
);
