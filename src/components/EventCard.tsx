import type { AgentEvent } from "../lib/types";

export function EventCard({ event: ev }: { event: AgentEvent }) {
  switch (ev.kind) {
    case "AssistantText":
      return (
        <div className="event assistant">
          <div className="label">assistant</div>
          <pre>{ev.text}</pre>
        </div>
      );

    case "UserEcho":
      return (
        <div className="event">
          <div className="label">user</div>
          <pre>{ev.text}</pre>
        </div>
      );

    case "ToolCallStarted":
      return (
        <div className="event tool">
          <div className="label">tool · {ev.name}</div>
          <pre>{ev.args_preview}</pre>
        </div>
      );

    case "ToolCallUpdated":
      return (
        <div className="event tool">
          <div className="label">tool · {ev.status.type.toLowerCase()}</div>
          <pre>{ev.output_preview ?? ""}</pre>
        </div>
      );

    case "Plan":
      return (
        <div className="event">
          <div className="label">plan</div>
          <pre>
            {ev.items
              .map((i) => `• [${i.status.type}] ${i.title}`)
              .join("\n")}
          </pre>
        </div>
      );

    case "AvailableCommands":
      return (
        <div className="event">
          <div className="label">commands</div>
          <pre>{ev.commands.map((c) => "/" + c.name).join(" ")}</pre>
        </div>
      );

    case "ModeChanged":
      return (
        <div className="event">
          <div className="label">mode</div>
          <pre>{ev.mode_id}</pre>
        </div>
      );

    case "StateChanged":
      return (
        <div className="event">
          <div className="label">state → {ev.state.type.toLowerCase()}</div>
        </div>
      );

    case "RequestPermission":
      return (
        <div className="event permission">
          <div className="label">permission · {ev.tool_name}</div>
          <pre>{ev.summary}</pre>
        </div>
      );

    case "RawOutput": {
      const text = new TextDecoder("utf-8", { fatal: false }).decode(
        new Uint8Array(ev.bytes),
      );
      return (
        <div className="event raw">
          <div className="label">raw output</div>
          <pre>{text}</pre>
        </div>
      );
    }

    case "HeuristicState":
      return (
        <div className="event">
          <div className="label">heuristic</div>
          <pre>{ev.label}</pre>
        </div>
      );

    case "Error":
      return (
        <div className="event error">
          <div className="label">error{ev.fatal ? " (fatal)" : ""}</div>
          <pre>{ev.message}</pre>
        </div>
      );
  }
}
