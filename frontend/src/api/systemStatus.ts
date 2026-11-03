/** Response of GET /api/v1/system/status. */
export interface SystemStatus {
  service: string;
  apiVersion: string;
  databaseTime: string;
}

export class ApiError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isSystemStatus(value: unknown): value is SystemStatus {
  return (
    isRecord(value) &&
    typeof value.service === 'string' &&
    typeof value.apiVersion === 'string' &&
    typeof value.databaseTime === 'string'
  );
}

/**
 * Requests the status through the same origin: in every environment the
 * page and the API are served by the Caddy edge, so no host or port is
 * configured here.
 */
export async function fetchSystemStatus(signal?: AbortSignal): Promise<SystemStatus> {
  const response = await fetch('/api/v1/system/status', {
    headers: { Accept: 'application/json' },
    ...(signal === undefined ? {} : { signal }),
  });
  const body: unknown = await response.json().catch(() => null);

  if (!response.ok) {
    const title = isRecord(body) && typeof body.title === 'string' ? body.title : response.statusText;
    throw new ApiError(response.status, title || `HTTP ${String(response.status)}`);
  }
  if (!isSystemStatus(body)) {
    throw new ApiError(response.status, 'Unexpected response from the API');
  }
  return body;
}
