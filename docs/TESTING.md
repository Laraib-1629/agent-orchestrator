# Testing

## Run all tests

```bash
pnpm test
```

Runs Vitest across all packages except `@aoagents/ao-web`.

## Run tests for a specific package

```bash
pnpm --filter @aoagents/ao-web test
pnpm --filter @aoagents/ao-core test
pnpm --filter @aoagents/ao-plugin-agent-claude-code test
```

Replace the filter value with any package name from `packages/`.

## Watch mode

```bash
pnpm --filter @aoagents/ao-core test:watch
pnpm --filter @aoagents/ao-web test:watch
```

> `test:watch` is only available in packages that declare it (e.g. `ao-core`, `ao-web`). Plugin packages use `vitest run` and do not expose a watch script.

## Integration tests

```bash
pnpm build
pnpm test:integration
```

Requires a built workspace **and** system-level dependencies on `PATH`: `tmux`, `gh`, and any agent CLIs you intend to test (e.g. `claude`). Missing binaries cause obscure failures rather than clear errors.

## Before pushing

```bash
pnpm build && pnpm typecheck && pnpm lint && pnpm test
```

All four must pass. Tests alone are not sufficient — type errors and lint violations are also CI failures.

## Test file conventions

- Location: `src/__tests__/` within each package
- Naming: `{Module}.test.ts` or `{Component}.test.tsx`
- Framework: Vitest + `@testing-library/react` for web components
- `any` types and `console.log` are allowed in test files
