<?php

declare(strict_types=1);

/*
 * Security negative controls of FCRM-FND-010B (run-controls.php): each entry
 * removes or weakens one protection in a copy of the backend, and the named
 * tests must then fail. A control that still passes means the tests no
 * longer guard that protection.
 *
 * search must occur exactly once in file; tests is a PHPUnit --filter.
 */

return [
    // Tenant isolation (FCRM-002 TI-01, TI-04, TI-05).
    ['membership of any user accepted', 'src/Organizations/Infrastructure/Persistence/DbalOrganizationReadModel.php',
        "WHERE organization_id = ? AND user_id = ? AND status = 'ACTIVE'\"", "WHERE organization_id = ? AND (user_id = ? OR true) AND status = 'ACTIVE'\"",
        'TenantAuthorizationTest::testAForeignOrganizationIsIndistinguishableFromAnUnknownOne'],
    ['removed membership accepted', 'src/Organizations/Infrastructure/Persistence/DbalOrganizationReadModel.php',
        "WHERE organization_id = ? AND user_id = ? AND status = 'ACTIVE'\"", 'WHERE organization_id = ? AND user_id = ?"',
        'TenantAuthorizationTest::testRemovingAMembershipTakesEffectOnTheNextRequest'],
    ['member lookup not scoped to the organization (IDOR)', 'src/Organizations/Infrastructure/Persistence/DbalOrganizationReadModel.php',
        "WHERE organization_id = ? AND id = ? AND status = 'ACTIVE'\"", "WHERE (organization_id = ? OR true) AND id = ? AND status = 'ACTIVE'\"",
        'TenantAuthorizationTest::testGuessedResourceIdsAreNotFound'],
    ['403 instead of 404 for a foreign organization', 'src/Organizations/Http/Tenant/TenantGuard.php',
        "            throw ProblemException::notFound();\n", "            throw ProblemException::forbidden();\n",
        'TenantAuthorizationTest::testAForeignOrganizationIsIndistinguishableFromAnUnknownOne'],
    ['permission not checked', 'src/Organizations/Http/Tenant/TenantGuard.php',
        'if (!$this->authorization->isGranted($permission->value, $context)) {', 'if (false) {',
        'TenantGuardTest'],
    ['voter ignores whose membership it is', 'src/Organizations/Http/Tenant/TenantPermissionVoter.php',
        '&& $token->getUserIdentifier() === $subject->userId->toRfc4122()', '',
        'TenantPermissionVoterTest'],
    ['REP may see e-mail addresses', 'src/Organizations/Domain/RolePolicy.php',
        "'REP' => [Permission::OrganizationView, Permission::MembershipList],", "'REP' => [Permission::OrganizationView, Permission::MembershipList, Permission::MembershipViewEmail],",
        'RolePolicyTest|TenantAuthorizationTest::testEmailAddressesNeedThePermission'],
    ['tenant route without a permission', 'src/Organizations/Http/Api/OrganizationController.php',
        "    #[TenantPermission(Permission::MembershipList)]\n    public function members(", '    public function members(',
        'RouteSecurityTest::testEveryTenantRouteHasAValidatedOrganizationAndExactlyOnePermission|TenantAuthorizationTest::testEmailAddressesNeedThePermission'],
    ['tenant route that fails open without a permission', 'src/Organizations/Http/Tenant/TenantGuard.php',
        'if (1 !== \count($permissions)) {', 'if (false) {',
        'TenantGuardTest::testATenantRouteWithoutAPermissionFailsClosed'],
    ['organization role promoted to a Symfony role', 'src/Identity/Infrastructure/Security/SecurityUser.php',
        "return ['ROLE_USER'];", "return ['ROLE_USER', 'ROLE_ADMIN'];",
        'SecurityUserTest::testOnlyRoleUser'],
    ['client-supplied query parameters accepted', 'src/Shared/Http/Query/Pagination.php',
        "if (!\\in_array(\$name, ['page', 'pageSize'], true)) {", 'if (false) {',
        'TenantAuthorizationTest::testClientSuppliedOrganizationIdsAreIgnoredOrRefused'],

    // Authentication and sessions.
    ['no new session ID at login (fixation)', 'config/packages/security.yaml',
        'session_fixation_strategy: migrate', 'session_fixation_strategy: none',
        'AuthenticationTest::testLoginAlwaysIssuesANewSessionId'],
    ['unknown e-mail answers without hashing (timing)', 'src/Identity/Infrastructure/Security/UserProvider.php',
        '$this->hashers->getPasswordHasher(SecurityUser::class)->hash(bin2hex(random_bytes(16)));', '',
        'UserProviderTest::testAnUnknownAddressCostsOneHashAndNamesNoAddress'],
    ['disabled user may log in', 'src/Identity/Infrastructure/Security/UserChecker.php',
        'throw new DisabledException();', '',
        'AuthenticationTest::testFailedLoginsAreIndistinguishable'],
    ['disabled account revealed by its answer', 'src/Identity/Http/Security/LoginFailureHandler.php',
        "        return ProblemResponse::of(\$request, ProblemException::invalidCredentials());\n", "        return ProblemResponse::of(\$request, 'disabled' === \$reason ? ProblemException::forbidden() : ProblemException::invalidCredentials());\n",
        'AuthenticationTest::testFailedLoginsAreIndistinguishable'],
    ['password hash stored in the session', 'src/Identity/Infrastructure/Security/SecurityUser.php',
        "return ['id' => \$this->id, 'credentials' => \$this->credentials, 'authenticatedAt' => \$this->authenticatedAt];", "return ['id' => \$this->id, 'credentials' => \$this->credentials, 'authenticatedAt' => \$this->authenticatedAt, 'hash' => \$this->passwordHash];",
        'SecurityUserTest::testTheSessionFormHasNeitherTheHashNorTheEmail|AuthenticationTest::testTheSessionStoresNoCredentialsAndNoTenant'],
    ['session survives disabling the user', 'src/Identity/Infrastructure/Security/SecurityUser.php',
        '            && !$user->disabled', '',
        'AuthenticationTest::testDisablingAUserEndsTheirSessionsAndLogins'],
    ['no absolute session lifetime', 'src/Identity/Infrastructure/Security/SecurityUser.php',
        '            && !$user->expired', '',
        'AuthenticationTest::testTheAbsoluteLifetimeEndsTheSession|UserProviderTest::testARefreshAfterTheAbsoluteLifetimeEndsTheSession'],
    ['session survives a password change elsewhere', 'src/Identity/Infrastructure/Security/SecurityUser.php',
        '&& hash_equals($this->credentials, $user->credentials)', '',
        'AuthenticationTest::testChangingTheOwnPasswordKeepsThisSessionAndEndsTheOthers|AuthenticationTest::testAnOperatorPasswordResetEndsEverySession'],
    ['logout keeps the session row', 'src/Identity/Http/Api/AuthController.php',
        "        if (\$request->hasPreviousSession()) {\n            \$request->getSession()->invalidate();\n        }\n", '',
        'AuthenticationTest::testLogoutEndsTheSessionOnTheServer'],

    // Request forgery.
    ['Origin not checked', 'src/Shared/Http/Security/RequestOriginGuard.php',
        'if ($origin !== $request->getSchemeAndHttpHost()) {', 'if (false) {',
        'RequestForgeryTest::testLoginFromAnotherOriginIsRefusedBeforeAuthentication'],
    ['CSRF token not checked', 'src/Shared/Http/Security/RequestOriginGuard.php',
        'if (!$request->getSession()->has($this->authenticatedSessionKey)) {', 'if (true) {',
        'RequestForgeryTest::testTheSessionTokenIsRequiredForAuthenticatedUnsafeRequests|AuthenticationTest::testLogoutNeedsTheCsrfTokenOfItsSession'],
    ['an authenticated route exempted from the token', 'config/services.yaml',
        'flowcrm.security.csrf_exempt_routes: [api_v1_auth_login]', 'flowcrm.security.csrf_exempt_routes: [api_v1_auth_login, api_v1_me_password]',
        'RequestForgeryTest::testTheSessionTokenIsRequiredForAuthenticatedUnsafeRequests'],
    ['form and text bodies accepted', 'src/Shared/Http/Security/RequestOriginGuard.php',
        "&& 'json' !== \$request->getContentTypeFormat()) {", '&& false) {',
        'RequestForgeryTest::testBodiesMustBeJson'],

    // Login throttling.
    ['no login throttling', 'config/packages/security.yaml',
        "            login_throttling:\n                limiter: App\\Identity\\Infrastructure\\Security\\LoginRateLimiter\n", '',
        'LoginThrottlingTest::testTheSixthFailureOfAnAccountFromOneClientIsRefusedEvenWithTheRightPassword'],
    ['a success resets every window', 'src/Identity/Infrastructure/Security/LoginRateLimiter.php',
        "        \$this->accountAndIpLimiter(\$request)->reset();\n", "        foreach (\$this->getLimiters(\$request) as \$limiter) {\n            \$limiter->reset();\n        }\n",
        'LoginThrottlingTest::testOneClientIpIsLimitedAcrossAccounts|LoginRateLimiterTest'],
    ['forwarded host and port trusted', 'config/packages/framework.yaml',
        "trusted_headers: ['x-forwarded-for', 'x-forwarded-proto']", "trusted_headers: ['x-forwarded-for', 'x-forwarded-proto', 'x-forwarded-host', 'x-forwarded-port']",
        'SecurityConfigurationTest::testOnlyTheClientAddressAndSchemeAreTakenFromTheEdge'],
];
