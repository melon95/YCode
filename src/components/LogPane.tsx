import { useEffect, useRef } from "react";
import { useStore } from "../lib/store";
import { EventCard } from "./EventCard";

export function LogPane() {
  const activeId = useStore((s) => s.activeId);
  const events = useStore((s) => (s.activeId ? s.events[s.activeId] : undefined));
  const ref = useRef<HTMLDivElement>(null);

  // Keep the log pinned to the bottom as new events arrive. Don't fight the
  // user if they've scrolled up — only auto-scroll when we're already near
  // the bottom.
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
    if (nearBottom) el.scrollTop = el.scrollHeight;
  }, [events]);

  if (!activeId) {
    return (
      <div className="log" ref={ref}>
        <div className="empty">Select a session, or create a new one.</div>
      </div>
    );
  }
  if (!events || events.length === 0) {
    return (
      <div className="log" ref={ref}>
        <div className="empty">No events yet for this session.</div>
      </div>
    );
  }

  return (
    <div className="log" ref={ref}>
      {events.map((ev, i) => (
        <EventCard key={i} event={ev} />
      ))}
    </div>
  );
}
