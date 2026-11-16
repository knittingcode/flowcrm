<?php

declare(strict_types=1);

namespace App\CRM\Http\Api;

use App\CRM\Application\AccountNotFound;
use App\CRM\Application\AccountReadModel;
use App\CRM\Application\AccountView;
use App\CRM\Application\ManageAccounts;
use App\CRM\Domain\AccountArchived;
use App\CRM\Domain\AccountDetails;
use App\CRM\Domain\InvalidAccountDetails;
use App\Organizations\Api\Permission;
use App\Organizations\Api\TenantContext;
use App\Organizations\Api\TenantPermission;
use App\Shared\Http\Json\JsonBody;
use App\Shared\Http\Problem\ProblemException;
use App\Shared\Http\Query\Pagination;
use App\Shared\Http\RequestId;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;
use Symfony\Component\Routing\Requirement\Requirement;
use Symfony\Component\Uid\Uuid;

/**
 * Accounts (customer companies) of an organization. TenantGuard has resolved
 * the active membership and checked the declared permission before any of
 * these runs. The organization comes only from the route: the body has no
 * organization member (an unknown member is a 422), and every read and write
 * is filtered by the organization, so an account ID of another organization
 * is the same 404 as an unknown one.
 */
final readonly class AccountController
{
    private const BASE = '/api/v1/organizations/{organizationId}/accounts';
    private const ORGANIZATION = ['organizationId' => Requirement::UUID];
    private const ACCOUNT = ['organizationId' => Requirement::UUID, 'accountId' => Requirement::UUID];

    public function __construct(
        private AccountReadModel $accounts,
        private ManageAccounts $manage,
    ) {
    }

    #[Route(self::BASE, name: 'api_v1_accounts', requirements: self::ORGANIZATION, methods: ['GET'])]
    #[TenantPermission(Permission::AccountView)]
    public function list(Request $request, TenantContext $tenant): JsonResponse
    {
        $pagination = Pagination::of($request);
        [$accounts, $total] = $this->accounts->page($tenant->organizationId, ($pagination->page - 1) * $pagination->pageSize, $pagination->pageSize);

        return new JsonResponse([
            'data' => array_map(self::view(...), $accounts),
            'meta' => ['page' => $pagination->page, 'pageSize' => $pagination->pageSize, 'total' => $total],
        ]);
    }

    #[Route(self::BASE, name: 'api_v1_account_create', requirements: self::ORGANIZATION, methods: ['POST'])]
    #[TenantPermission(Permission::AccountManage)]
    public function create(Request $request, TenantContext $tenant): JsonResponse
    {
        $id = $this->manage->create($tenant, self::details($request), self::requestId($request));

        return new JsonResponse(self::view($this->account($tenant, $id)), Response::HTTP_CREATED);
    }

    #[Route(self::BASE.'/{accountId}', name: 'api_v1_account', requirements: self::ACCOUNT, methods: ['GET'])]
    #[TenantPermission(Permission::AccountView)]
    public function show(string $accountId, TenantContext $tenant): JsonResponse
    {
        return new JsonResponse(self::view($this->account($tenant, Uuid::fromString($accountId))));
    }

    /** Replaces the details; an archived account is a 409. */
    #[Route(self::BASE.'/{accountId}', name: 'api_v1_account_update', requirements: self::ACCOUNT, methods: ['PUT'])]
    #[TenantPermission(Permission::AccountManage)]
    public function update(string $accountId, Request $request, TenantContext $tenant): JsonResponse
    {
        $id = Uuid::fromString($accountId);
        try {
            $this->manage->update($tenant, $id, self::details($request), self::requestId($request));
        } catch (AccountNotFound) {
            throw ProblemException::notFound();
        } catch (AccountArchived) {
            throw ProblemException::conflict();
        }

        return new JsonResponse(self::view($this->account($tenant, $id)));
    }

    #[Route(self::BASE.'/{accountId}/archive', name: 'api_v1_account_archive', requirements: self::ACCOUNT, methods: ['POST'])]
    #[TenantPermission(Permission::AccountArchive)]
    public function archive(string $accountId, Request $request, TenantContext $tenant): Response
    {
        try {
            $this->manage->archive($tenant, Uuid::fromString($accountId), self::requestId($request));
        } catch (AccountNotFound) {
            throw ProblemException::notFound();
        }

        return new Response(status: Response::HTTP_NO_CONTENT);
    }

    private function account(TenantContext $tenant, Uuid $id): AccountView
    {
        return $this->accounts->account($tenant->organizationId, $id) ?? throw ProblemException::notFound();
    }

    private static function details(Request $request): AccountDetails
    {
        $body = JsonBody::fields($request, ['name'], ['website', 'email', 'phone']);
        try {
            return AccountDetails::of($body['name'] ?? '', $body['website'], $body['email'], $body['phone']);
        } catch (InvalidAccountDetails $e) {
            $errors = [];
            foreach ($e->violations as $field => $code) {
                $errors[] = ['pointer' => '/'.$field, 'code' => $code];
            }

            throw ProblemException::validation($errors);
        }
    }

    private static function requestId(Request $request): Uuid
    {
        return Uuid::fromString(RequestId::of($request));
    }

    /** @return array<string, string|null> */
    private static function view(AccountView $account): array
    {
        return [
            'id' => $account->id->toRfc4122(),
            'name' => $account->name,
            'website' => $account->website,
            'email' => $account->email,
            'phone' => $account->phone,
            'createdAt' => self::instant($account->createdAt),
            'updatedAt' => self::instant($account->updatedAt),
            'archivedAt' => null === $account->archivedAt ? null : self::instant($account->archivedAt),
        ];
    }

    private static function instant(\DateTimeImmutable $at): string
    {
        return $at->setTimezone(new \DateTimeZone('UTC'))->format('Y-m-d\TH:i:s\Z');
    }
}
