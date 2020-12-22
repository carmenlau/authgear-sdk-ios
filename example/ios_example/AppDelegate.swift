import Authgear
import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    let wechatAppID = "wxa2f631873c63add1"
    var appContainer = App()

    func configureAuthgear(clientId: String, endpoint: String, isThirdParty: Bool) {
        appContainer.container = Authgear(clientId: clientId, endpoint: endpoint, isThirdParty: isThirdParty)
        appContainer.container?.delegate = self
        appContainer.container?.configure()

        WXApi.registerApp(wechatAppID, universalLink: "https://authgear-example-carmenlau.pandawork.com/")
        WXApi.startLog(by: .detail) { log in
            print(#line, log)
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    // Handle redirection after OAuth completed or failed
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard let c = appContainer.container else {
            // not yet configured
            return true
        }
        return c.application(app, open: url, options: options)
    }
}

extension AppDelegate: AuthgearDelegate {
    func sendWeChatAuthRequest(_ state: String) {
        let req = SendAuthReq()
        req.openID = wechatAppID
        req.scope = "snsapi_userinfo"
        req.state = state
        WXApi.send(req)
        print(#line, "sendWeChatAuthRequest: \(state)")
    }

    func authgearSessionStateDidChange(_ container: Authgear, reason: SessionStateChangeReason) {}
}

extension AppDelegate: WXApiDelegate {
    func onReq(_ req: BaseReq) {}

    func onResp(_ resp: BaseResp) {
        if resp.isKind(of: SendAuthResp.self) {
            if resp.errCode == 0 {
                let _resp = resp as! SendAuthResp
                if let code = _resp.code, let state = _resp.state {
                    appContainer.container?.weChatAuthCallback(code: code, state: state) { result in
                        switch result {
                        case .success():
                            print(#line, "wechat callback received")
                        case let .failure(error):
                            print(#line, error)
                        }
                    }
                }
            } else {
                print(#line, "failed in wechat login: \(resp.errStr)")
            }
        }
    }
}
