# Repository conventions

- This is a public repository. Track maintained implementation, public contracts, consumer documentation, build tooling, and relevant tests only.
- Keep investigation, iteration plans, private references, machine configuration, and verification evidence in the ignored `doc/dev/` directory. Never force-add it or link public documentation to it.
- Name APIs, files, and documentation by responsibility. Do not encode development stages, priorities, or replacement history in names. Semantic package and protocol versions remain explicit.
- Native cores have no dependency on React Native, Expo, or any application business model. Optional UI and system-storage integration remain separate modules.
- Applications own authentication, endpoint protocols, account isolation, message publishing, and interpretation of server responses. Never persist authorization headers, remote URLs, or response bodies in task history.
- A completed network request is not necessarily a completed task. Save or validate the result before declaring success. Reject stale attempt callbacks; cancellation must not report failure or success later.
- Retry starts a new attempt. Do not claim pause, background execution, or byte-range recovery without implementing and testing their separate contracts.
- Consumer applications and manual verification hosts belong to the integration repository. Never copy plugin implementation into hosts or use generated projects as source.
- Pin dependencies and preserve applicable third-party notices. Do not commit downloaded SDKs, build products, credentials, signing material, or local paths.
- Run affected local logic checks and builds. Report compilation, isolated tests, device behavior, and real server behavior separately.
- Do not start devices, real transfers to private services, paid CI, remote publication, or package releases without user authorization. Local loopback fixtures are appropriate for deterministic tests.
