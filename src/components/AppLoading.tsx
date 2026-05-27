// Full-window loading curtain shown until the initial IPC fetches resolve.
// Designed as a typographic specimen: italic display wordmark + a hairline
// rule with a single terracotta head scanning across it. The whole curtain
// fades out (300ms) once `ready` flips, then is removed from the layout via
// `visibility: hidden` so it stops eating clicks.

interface Props {
  ready: boolean;
}

export function AppLoading({ ready }: Props) {
  return (
    <div
      className={"app-loading" + (ready ? " loaded" : "")}
      role="status"
      aria-live="polite"
      aria-hidden={ready}
    >
      <div className="app-loading-mark">
        <span className="app-loading-word">ycode</span>
        <span className="app-loading-bar" aria-hidden />
        <span className="app-loading-caption">preparing workbench</span>
      </div>
    </div>
  );
}
