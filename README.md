# FlowCRM

A customer relationship management platform for teams that need a clear view of their customers, sales opportunities, and day-to-day activities.

FlowCRM is designed around practical sales workflows, with a focus on data ownership, access control, automation, and maintainable application architecture.

## Planned Features

- Organization and user management
- Role-based access control
- Customer and contact management
- Sales pipelines and opportunity tracking
- Tasks, notes, and activity history
- Sales dashboards and reporting
- Notifications and background processing
- Data import and export
- Audit logs for important operations

## Technology Stack

| Layer | Technology |
| --- | --- |
| Backend | PHP, Symfony |
| Frontend | React, TypeScript |
| Database | PostgreSQL |
| Cache | Redis |
| Messaging | RabbitMQ, Symfony Messenger |
| Infrastructure | Docker, Docker Compose |
| CI/CD | GitHub Actions |
| Testing | PHPUnit, Playwright |

## Architecture

FlowCRM will follow a modular monolith architecture.

Business capabilities will be organized into clearly separated modules. Domain logic will remain independent of HTTP controllers, persistence details, and external integrations.

The initial design will prioritize:

- Clear module boundaries
- Domain-driven design principles
- API-first communication
- Tenant data isolation
- Asynchronous background processing
- Testable business logic

## Development Roadmap

- [ ] Define domain boundaries and data model
- [ ] Set up Symfony and React applications
- [ ] Configure Docker, Makefile, and CI
- [ ] Implement authentication and authorization
- [ ] Build customer and contact management
- [ ] Implement sales pipelines
- [ ] Add activities and notifications
- [ ] Implement reporting and audit logs
- [ ] Complete testing and security review
- [ ] Prepare a public demo

## Project Status

**Planning**

The repository currently contains the initial product scope. Implementation has not started.

The roadmap and technology choices may evolve as architectural decisions are made.

## License

License to be determined.