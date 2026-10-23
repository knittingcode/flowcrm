import { Route, Routes } from 'react-router';
import { RequireAuth } from './auth/RequireAuth.tsx';
import { OrganizationPage } from './features/organization/OrganizationPage.tsx';
import { AppShell } from './pages/AppShell.tsx';
import { HomePage } from './pages/HomePage.tsx';
import { LoginPage } from './pages/LoginPage.tsx';
import { NotFoundPage } from './pages/NotFoundPage.tsx';

/** Every page except the login requires a session; unknown addresses are "not found" after the login. */
export function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route
        element={
          <RequireAuth>
            <AppShell />
          </RequireAuth>
        }
      >
        <Route index element={<HomePage />} />
        <Route path="/o/:organizationId" element={<OrganizationPage />} />
        <Route path="*" element={<NotFoundPage />} />
      </Route>
    </Routes>
  );
}
