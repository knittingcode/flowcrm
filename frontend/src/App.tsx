import { SystemStatusPanel } from './features/system-status/SystemStatusPanel.tsx';

export function App() {
  return (
    <div className="shell">
      <header className="shell-header">
        <span className="brand">FlowCRM</span>
        <span className="environment">development foundation</span>
      </header>
      <main className="shell-main">
        <h1>Application shell</h1>
        <p>
          The CRM features are not built yet. This page checks that the frontend, the API and the
          database work together through the edge.
        </p>
        <SystemStatusPanel />
      </main>
    </div>
  );
}
