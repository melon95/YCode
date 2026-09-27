import Foundation

public enum YCodePiTitleBridge {
    public struct State: Decodable, Sendable {
        public let terminalID: String
        public let sessionID: String
        public let path: String?
        public let name: String?
    }

    public static func directory(dataRoot: URL) -> URL { dataRoot.appendingPathComponent("title-bridge", isDirectory: true) }

    public static func prepare(dataRoot: URL) throws -> URL {
        let directory = directory(dataRoot: dataRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("pi-title-bridge.mjs")
        if (try? String(contentsOf: url, encoding: .utf8)) != source {
            try source.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    public static func state(dataRoot: URL, terminalID: String) -> State? {
        guard let data = try? Data(contentsOf: directory(dataRoot: dataRoot).appendingPathComponent(terminalID + ".state.json")) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    public static func rename(dataRoot: URL, terminalID: String, sessionID: String?, title: String) -> YCodeAgentSessionTitleWriter.Outcome {
        let directory = directory(dataRoot: dataRoot)
        let requestID = UUID().uuidString
        let request = directory.appendingPathComponent(terminalID + ".request.json")
        let ack = directory.appendingPathComponent(terminalID + ".ack.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "requestID": requestID, "sessionID": sessionID ?? "", "name": title,
                "expiresAt": Date().timeIntervalSince1970 * 1_000 + 5_000
            ])
            try data.write(to: request, options: .atomic)
            defer { try? FileManager.default.removeItem(at: request) }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let data = try? Data(contentsOf: ack),
                   let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   value["requestID"] as? String == requestID {
                    if let error = value["error"] as? String { return .failed(error) }
                    return value["name"] as? String == title ? .written : .failed("pi 未确认新名称")
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
            return .failed("pi 标题同步未响应；请重新启动此会话以加载标题扩展")
        } catch { return .failed(error.localizedDescription) }
    }

    // The bridge calls pi's public extension API on the same event loop as its TUI.
    // No simulated keystrokes, conversation messages, or external edits to its live tree.
    static let source = #"""
    import fs from 'node:fs';
    import path from 'node:path';
    export default function(pi) {
      const id = process.env.YCODE_TERMINAL_ID;
      const root = process.env.YCODE_NATIVE_DATA_ROOT;
      if (!id || !root) return;
      const dir = path.join(root, 'title-bridge');
      const file = suffix => path.join(dir, id + suffix + '.json');
      let ctx, watcher, handled;
      function write(suffix, value) {
        const target = file(suffix), temp = target + '.' + process.pid + '.tmp';
        fs.writeFileSync(temp, JSON.stringify(value), {mode: 0o600});
        fs.renameSync(temp, target);
      }
      function publish() {
        if (!ctx) return;
        write('.state', {terminalID: id, sessionID: ctx.sessionManager.getSessionId(),
          path: ctx.sessionManager.getSessionFile() ?? null, name: pi.getSessionName() ?? null});
      }
      function fallbackWatch() {
        watcher?.close(); watcher = undefined;
        fs.watchFile(file('.request'), {interval: 400}, consume);
      }
      function consume() {
        if (!ctx) return;
        let r;
        try { r = JSON.parse(fs.readFileSync(file('.request'), 'utf8')); } catch { return; }
        if (!r.requestID || handled === r.requestID || Date.now() > r.expiresAt) return;
        handled = r.requestID;
        try {
          if (r.sessionID && r.sessionID !== ctx.sessionManager.getSessionId()) throw Error('会话已切换，请重试');
          if (typeof r.name !== 'string' || !r.name.trim()) throw Error('名称不能为空');
          pi.setSessionName(r.name);
          publish();
          write('.ack', {requestID: r.requestID, name: pi.getSessionName()});
        } catch (e) { try { write('.ack', {requestID: r.requestID, error: String(e.message ?? e)}); } catch {} }
      }
      pi.on('session_start', (_event, context) => {
        ctx = context;
        fs.mkdirSync(dir, {recursive: true, mode: 0o700});
        watcher?.close();
        fs.unwatchFile(file('.request'), consume);
        try {
          watcher = fs.watch(dir, (_event, name) => {
            if (String(name) === id + '.request.json') consume();
          });
          watcher.on('error', fallbackWatch);
        } catch { fallbackWatch(); }
        publish();
        consume();
      });
      pi.on('session_info_changed', () => { try { publish(); } catch {} });
      pi.on('session_shutdown', () => {
        watcher?.close(); watcher = undefined; ctx = undefined;
        fs.unwatchFile(file('.request'), consume);
        try { fs.unlinkSync(file('.state')); } catch {}
      });
    }
    """#
}
