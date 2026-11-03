import { useCallback, useEffect, useState } from 'react';
import { ApiError, fetchSystemStatus, type SystemStatus } from '../../api/systemStatus.ts';

type State =
  | { kind: 'loading' }
  | { kind: 'success'; status: SystemStatus }
  | { kind: 'error'; message: string };

function describe(error: unknown): string {
  if (error instanceof ApiError) {
    return `The API answered ${String(error.status)}: ${error.message}`;
  }
  return 'The API could not be reached.';
}

export function SystemStatusPanel() {
  const [state, setState] = useState<State>({ kind: 'loading' });
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    fetchSystemStatus(controller.signal).then(
      (status) => {
        setState({ kind: 'success', status });
      },
      (error: unknown) => {
        if (!controller.signal.aborted) {
          setState({ kind: 'error', message: describe(error) });
        }
      },
    );
    return () => {
      controller.abort();
    };
  }, [attempt]);

  const retry = useCallback(() => {
    setState({ kind: 'loading' });
    setAttempt((value) => value + 1);
  }, []);

  return (
    <section className="status" aria-labelledby="status-heading" aria-busy={state.kind === 'loading'}>
      <h2 id="status-heading">API connection</h2>
      {state.kind === 'loading' && <p role="status">Checking the API…</p>}
      {state.kind === 'success' && (
        <dl data-testid="status-result">
          <dt>Service</dt>
          <dd>{state.status.service}</dd>
          <dt>API version</dt>
          <dd>{state.status.apiVersion}</dd>
          <dt>Database time (UTC)</dt>
          <dd>
            <time dateTime={state.status.databaseTime}>{state.status.databaseTime}</time>
          </dd>
        </dl>
      )}
      {state.kind === 'error' && (
        <div role="alert">
          <p>{state.message}</p>
          <button type="button" onClick={retry}>
            Retry
          </button>
        </div>
      )}
    </section>
  );
}
