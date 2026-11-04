import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey]
        // Preserve the tiny synchronous diagnostic path; rendering operations use
        // asynchronous native I/O so Safari's request thread never blocks.
        let operation = (message as? [String: Any])?["operation"] as? String ?? ""
        if operation == "ping" || !SafariNativeRouter.operations.contains(operation) ||
            (try? SafariNativeMessage.envelope(message)) == nil {
            finish(SafariNativeMessage.reply(to: message), context: context)
        } else {
            Task { finish(await SafariNativeRouter.shared.handle(message), context: context) }
        }
    }

    private func finish(_ value: [String: Any], context: NSExtensionContext) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: value]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
