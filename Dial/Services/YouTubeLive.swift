import Observation
import OSLog
import SwiftUI
import UIKit
import WebKit

/// Live streams that play through YouTube's own embedded player (the supported way: nothing is taken out of the page).
/// Lofi Girl's radio streams are listed under Radio > Lo-fi, with the stream's own YouTube picture as the artwork.
let youtubeLog = Logger(subsystem: "com.nodescraper.dial", category: "youtube")

enum YouTubeLive {
    struct Stream { let id: String; let name: String }

    /// The live streams on Lofi Girl's channel (youtube.com/@LofiGirl/streams). Their video ids change now and then.
    static let lofiGirl: [Stream] = [
        Stream(id: "rFZHOHl-L8A", name: "lofi hip hop radio · beats to relax/study to"),
        Stream(id: "JD-kMIpDfnY", name: "lofi hip hop radio · beats to sleep/chill to"),
        Stream(id: "4xDzrJKXOOY", name: "synthwave radio · beats to chill/game to"),
        Stream(id: "E2vONfzoyRI", name: "jazz lofi radio · beats to chill/study to"),
        Stream(id: "A8jDx9TLMQc", name: "relaxing jazz radio · cozy music to study to"),
        Stream(id: "CwPCy1GLS38", name: "sad lofi radio · beats for rainy days"),
        Stream(id: "1Tl2FtV06qo", name: "asian lofi radio · beats to relax/study to"),
        Stream(id: "3PFJ9SETS4M", name: "lofi house radio · lounge music to chill to"),
        Stream(id: "0muHFBSiybw", name: "summer lofi radio · music for a better mood"),
        Stream(id: "VAlMDl00mYY", name: "sleep lofi radio · relaxing music to dream to"),
        Stream(id: "E_XmwjgRLz8", name: "chill guitar radio · music to study/relax to"),
        Stream(id: "N0snMcR6aaA", name: "relaxing piano radio · calm music to focus to"),
        Stream(id: "jXAEIWcGXwE", name: "classical music radio · songs to read/study to"),
        Stream(id: "GSfT7H87zq4", name: "synth ambient radio · deep space music to sleep to"),
        Stream(id: "S_MOd40zlYU", name: "dark ambient radio · music to escape/dream to"),
        Stream(id: "xORCbIptqcc", name: "sleep ambient music · relaxing radio to fall asleep to"),
        Stream(id: "IxPANmjPaek", name: "medieval lofi radio · beats to scribe manuscripts to"),
        Stream(id: "4t4AQ15yj1M", name: "christmas lofi radio · cozy ambience to relax to"),
        Stream(id: "0sfDth4lMLc", name: "halloween ambience · spooky lofi to get chills to"),
        Stream(id: "-OekvEFm1lo", name: "gentle rain ambience · cozy sound to chill to"),
        Stream(id: "q_4KI-ChIIs", name: "fireplace ambience · cozy sound to chill to"),
        Stream(id: "qGohtGC5Rtk", name: "Study With Me · Pomodoro"),
    ]

    /// The stream's own live picture, from YouTube (no key needed).
    static func thumbnail(_ id: String) -> String { "https://i.ytimg.com/vi/\(id)/maxresdefault_live.jpg" }

    static var lofiStations: [Station] { lofiGirl.map { Station(youtubeID: $0.id, name: $0.name, tag: "lofi", from: "Lofi Girl") } }
}

extension Station {
    init(youtubeID: String, name: String, tag: String, from: String) {
        self.id = "yt-\(youtubeID)"
        self.name = name
        self.streamURL = "youtube:\(youtubeID)"
        self.favicon = YouTubeLive.thumbnail(youtubeID)
        self.tags = tag
        self.country = from
        self.codec = nil
        self.bitrate = nil
        self.hls = nil
    }

    /// The YouTube video this station plays, when it is one of the YouTube streams.
    var youtubeID: String? { streamURL.hasPrefix("youtube:") ? String(streamURL.dropFirst(8)) : nil }
}

/// One long-lived YouTube player page. It has to sit in a window to play, so `YouTubeHost` keeps it on screen, invisible.
@MainActor @Observable
final class YouTubeEmbed: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    @ObservationIgnored let webView: WKWebView
    /// Playing or not, and whether it is buffering, as the page reports it.
    @ObservationIgnored var onState: ((_ playing: Bool, _ buffering: Bool) -> Void)?
    /// YouTube's error code when it refuses to play a stream.
    @ObservationIgnored var onError: ((Int) -> Void)?
    @ObservationIgnored private(set) var isActive = false
    private func note(_ text: String) { trail.append(text); youtubeLog.notice("\(text, privacy: .public)") }
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var pendingID: String?
    /// What the page has reported, for finding out why nothing plays.
    private(set) var trail: [String] = []

    private static let page = """
    <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>html,body{margin:0;background:#000;height:100%}#p{width:100%;height:100%}</style></head>
    <body><div id="p"></div>
    <script src="https://www.youtube.com/iframe_api" onerror="window.webkit.messageHandlers.dial.postMessage({t:'js',m:'iframe_api failed to load'})"></script>
    <script>
    var player, wanted = null;
    function post(m){ window.webkit.messageHandlers.dial.postMessage(m) }
    function onYouTubeIframeAPIReady(){
      player = new YT.Player('p', {width:'100%', height:'100%',
        playerVars:{playsinline:1, controls:0, autoplay:1, mute:1, rel:0, modestbranding:1, fs:0},
        events:{onReady:function(){ post({t:'ready'}) }, onStateChange:function(e){ if(e.data===1 && player.isMuted()){ player.unMute(); player.setVolume(100) } post({t:'state', s:e.data}) }, onError:function(e){ post({t:'error', c:e.data}) }}});
    }
    window.onerror = function(m){ post({t:'js', m:String(m)}) };
    function load(id){ if(player && player.loadVideoById) player.loadVideoById(id); }
    function play(){ if(player) player.playVideo() }
    function pause(){ if(player) player.pauseVideo() }
    function stop(){ if(player) player.stopVideo() }
    </script></body></html>
    """

    /// Keeps the page believing it is on screen, so it carries on when the app is in the background.
    private static let alwaysVisible = """
    Object.defineProperty(document,'hidden',{get:function(){return false}});
    Object.defineProperty(document,'visibilityState',{get:function(){return 'visible'}});
    document.addEventListener('visibilitychange',function(e){e.stopImmediatePropagation()},true);
    """

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.alwaysVisible, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = controller
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 240, height: 240), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        super.init()
        controller.add(WeakHandler(self), name: "dial")
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        webView.loadHTMLString(Self.page, baseURL: URL(string: "http://localhost"))
    }

    func load(_ id: String) {
        note("load \(id) (ready: \(ready))")
        isActive = true
        pendingID = id
        if ready { run("load('\(id)')") }
    }

    func play() { run("play()") }
    func pause() { run("pause()") }

    func stop() {
        guard isActive else { return }
        isActive = false
        pendingID = nil
        run("stop()")
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { note("page loaded") }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { note("page failed: \(error.localizedDescription)") }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { note("page failed: \(error.localizedDescription)") }
    }
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { note("web process ended") }
    }

    private func run(_ script: String) { webView.evaluateJavaScript(script, completionHandler: nil) }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["t"] as? String else { return }
        let state = body["s"] as? Int
        let code = body["c"] as? Int
        let note = body["m"] as? String
        MainActor.assumeIsolated {
            self.note(kind + (state.map { " \($0)" } ?? "") + (code.map { " \($0)" } ?? "") + (note.map { " \($0)" } ?? ""))
            switch kind {
            case "ready":
                ready = true
                if let id = pendingID { run("load('\(id)')") }
            case "state":
                guard isActive, let state else { return }
                onState?(state == 1 || state == 3, state == 3)
            case "error":
                if let code { onError?(code) }
            default: break
            }
        }
    }

    /// WebKit keeps its message handlers alive, so this one holds the player weakly.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: YouTubeEmbed?
        init(_ target: YouTubeEmbed) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }
}

/// Puts the YouTube player page in the window (small and nearly clear: it only has to be there to play).
struct YouTubeHost: UIViewRepresentable {
    let embed: YouTubeEmbed
    func makeUIView(context: Context) -> WKWebView { embed.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
