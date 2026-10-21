import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { SystemStatusPanel } from './SystemStatusPanel.tsx';

function jsonResponse(status: number, body: unknown, contentType = 'application/json'): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': contentType } });
}

describe('SystemStatusPanel', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('shows a loading state, then the status read from the API', async () => {
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(
      jsonResponse(200, { service: 'flowcrm-api', apiVersion: 'v1', databaseTime: '2026-10-21T12:00:00Z' }),
    );
    vi.stubGlobal('fetch', fetchMock);

    render(<SystemStatusPanel />);

    expect(screen.getByRole('status')).toHaveTextContent('Checking the API');
    expect(await screen.findByTestId('status-result')).toHaveTextContent('flowcrm-api');
    expect(screen.getByText('v1')).toBeInTheDocument();
    expect(screen.getByText('2026-10-21T12:00:00Z')).toHaveAttribute('dateTime', '2026-10-21T12:00:00Z');
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/v1/system/status',
      expect.objectContaining({ headers: { Accept: 'application/json' } }),
    );
  });

  it('reports a problem response with its status and title', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn<typeof fetch>().mockResolvedValue(
        jsonResponse(
          503,
          { type: '/problems/service-unavailable', title: 'Service Unavailable', status: 503 },
          'application/problem+json',
        ),
      ),
    );

    render(<SystemStatusPanel />);

    expect(await screen.findByRole('alert')).toHaveTextContent('The API answered 503: Service Unavailable');
  });

  it('reports an unreachable API and recovers on retry', async () => {
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValueOnce(
        jsonResponse(200, { service: 'flowcrm-api', apiVersion: 'v1', databaseTime: '2026-10-21T12:00:01Z' }),
      );
    vi.stubGlobal('fetch', fetchMock);

    render(<SystemStatusPanel />);
    expect(await screen.findByRole('alert')).toHaveTextContent('The API could not be reached.');

    await userEvent.click(screen.getByRole('button', { name: 'Retry' }));

    expect(await screen.findByTestId('status-result')).toHaveTextContent('2026-10-21T12:00:01Z');
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('rejects a successful response with an unexpected shape', async () => {
    vi.stubGlobal('fetch', vi.fn<typeof fetch>().mockResolvedValue(jsonResponse(200, { status: 'ok' })));

    render(<SystemStatusPanel />);

    expect(await screen.findByRole('alert')).toHaveTextContent('Unexpected response from the API');
  });
});
