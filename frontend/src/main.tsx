import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router';
import { App } from './App.tsx';
import { AuthProvider } from './auth/AuthProvider.tsx';
import './index.css';

const root = document.getElementById('root');
if (root === null) {
  throw new Error('The #root element is missing from index.html.');
}

createRoot(root).render(
  <StrictMode>
    <BrowserRouter>
      <AuthProvider>
        <App />
      </AuthProvider>
    </BrowserRouter>
  </StrictMode>,
);
