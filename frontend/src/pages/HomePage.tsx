import { Link, Navigate } from 'react-router';
import { useAuth } from '../auth/context.ts';

/** Organization selection: straight to the only organization, a choice for several. */
export function HomePage() {
  const { state } = useAuth();
  if (state.status !== 'authenticated') {
    return null;
  }
  const { memberships } = state.session;
  const only = memberships.length === 1 ? memberships[0] : undefined;
  if (only !== undefined) {
    return <Navigate to={`/o/${only.organizationId}`} replace />;
  }

  return (
    <>
      <h1>Organizations</h1>
      {memberships.length === 0 ? (
        <p>You are not a member of any organization yet. An administrator of your organization can add you.</p>
      ) : (
        <ul>
          {memberships.map((membership) => (
            <li key={membership.organizationId}>
              <Link to={`/o/${membership.organizationId}`}>{membership.organizationName}</Link> ({membership.role})
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
