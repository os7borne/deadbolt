import Foundation
import SafariServices

/// Native side of the Deadbolt Safari extension. Safari delivers `browser.runtime.sendNativeMessage` here;
/// it is forwarded unchanged to the Deadbolt app's socket (which checks this extension's code signature),
/// exactly like the Chrome bridge. No secrets are kept here.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]
        var reply: Any = ["ok": false, "error": "badRequest"]
        if let message, JSONSerialization.isValidJSONObject(message),
           let data = try? JSONSerialization.data(withJSONObject: message) {
            if let answer = BridgeClient.forward(data), let obj = try? JSONSerialization.jsonObject(with: answer) {
                reply = obj
            } else {
                reply = ["ok": false, "error": "notRunning"]
            }
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
