import { Link } from 'react-router';

/** The same page for an unknown address and for anything the user may not see. */
export function NotFoundPage() {
  return (
    <>
      <h1>Not found</h1>
      <p>This page does not exist, or you do not have access to it.</p>
      <p>
        <Link to="/">Go to the start page</Link>
      </p>
    </>
  );
}
