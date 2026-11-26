// Voice Memos stop on macOS 26.6 from inside ControlCenter (RE-27-BEHAVIOR 22.12). 27.3 stops through the VoiceMemos
// process's own element scene (onDidTapStopRecording); 26.6 has no scene, so the App Intent VoiceMemos.StopRecording is
// run through WorkflowKit's WFLinkActionWorkflowRunnerClient (BackgroundShortcutRunner, the path ControlCenter already
// uses for Shortcuts controls). An unentitled process is refused ("missing required entitlement") [V];
// ControlCenter holds com.apple.siri.VoiceShortcuts.xpc [V], whether that is enough is [?].
import Foundation
import os

@objc private protocol GGLNActionInit { func initWithIdentifier(_ i: String, mangledTypeName m: String, openAppWhenRun o: Bool, parameters p: [AnyObject]) -> AnyObject? }
@objc private protocol GGLinkRunnerInit { func initWithLinkAction(_ a: AnyObject, bundleIdentifier b: String, runSource s: String) -> AnyObject? }
@objc private protocol GGRunnerAPI { func setDelegate(_ d: AnyObject?); func start() }

/// WFWorkflowRunnerClientDelegate (informal); keeps the runner alive until it finishes.
final class VoiceMemosStopper: NSObject {
    private static var running: VoiceMemosStopper?
    private var runner: NSObject?
    private let log = Logger(subsystem: "com.goldengate.island", category: "voicememos")

    static func stop() {
        guard running == nil else { return }
        let s = VoiceMemosStopper()
        if s.start() { running = s }
    }

    private func start() -> Bool {
        dlopen("/System/Library/PrivateFrameworks/LinkServices.framework/LinkServices", RTLD_NOW)
        dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit", RTLD_NOW)
        func allocated(_ cls: String, _ sel: String) -> NSObject? {
            guard let c = NSClassFromString(cls) as? NSObject.Type,
                  let o = c.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
                  o.responds(to: NSSelectorFromString(sel)) else { return nil }
            return o
        }
        guard let a = allocated("LNAction", "initWithIdentifier:mangledTypeName:openAppWhenRun:parameters:"),
              let r = allocated("WFLinkActionWorkflowRunnerClient", "initWithLinkAction:bundleIdentifier:runSource:") else {
            log.error("Voice Memos stop: LinkServices/WorkflowKit API missing"); return false
        }
        // Mangled name from VoiceMemos.app Metadata.appintents/extract.actionsdata (26.6).
        guard let action = unsafeBitCast(a, to: GGLNActionInit.self)
                .initWithIdentifier("StopRecording", mangledTypeName: "10VoiceMemos13StopRecordingV", openAppWhenRun: false, parameters: []),
              let runner = unsafeBitCast(r, to: GGLinkRunnerInit.self)
                .initWithLinkAction(action, bundleIdentifier: "com.apple.VoiceMemos", runSource: "widget") as? NSObject,
              runner.responds(to: NSSelectorFromString("setDelegate:")), runner.responds(to: NSSelectorFromString("start")) else {
            log.error("Voice Memos stop: runner init failed"); return false
        }
        self.runner = runner
        unsafeBitCast(runner, to: GGRunnerAPI.self).setDelegate(self)
        unsafeBitCast(runner, to: GGRunnerAPI.self).start()
        log.notice("Voice Memos stop: started")
        return true
    }

    private func finish(_ error: NSError?, cancelled: Bool) {
        if let error { log.error("Voice Memos stop failed: \(error, privacy: .public)") }
        else { log.notice("Voice Memos stop: done (cancelled=\(cancelled))") }
        runner = nil
        Self.running = nil
    }

    @objc func workflowRunnerClient(_ c: AnyObject, didStartRunningWorkflowWithProgress p: Progress?) {}
    @objc func workflowRunnerClient(_ c: AnyObject, didFinishRunningWorkflowWithOutput o: AnyObject?, error: NSError?, cancelled: Bool) { finish(error, cancelled: cancelled) }
    @objc func workflowRunnerClient(_ c: AnyObject, didFinishRunningWorkflowWithError error: NSError?, cancelled: Bool) { finish(error, cancelled: cancelled) }
}
