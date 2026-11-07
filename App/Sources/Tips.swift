import SwiftUI
import TipKit

/// Points out touch and hold on a request, where Create Rule, Repeat and Copy live.
struct RequestActionsTip: Tip {
    var title: Text { Text("Change a Request").font(.app(.headline)) }
    var message: Text? { Text("Touch and hold a request to repeat it, copy it as cURL, or create a rule that mocks, blocks or pauses it.").font(.app(.subheadline)) }
}

/// Points out the swipe that turns on decryption for a host.
struct DecryptHostTip: Tip {
    var title: Text { Text("Decrypt a Host").font(.app(.headline)) }
    var message: Text? { Text("Swipe left on a host and tap Decrypt to read its HTTPS requests.").font(.app(.subheadline)) }
}
