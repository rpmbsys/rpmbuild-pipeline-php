# Права GitHub App и почему триггеры — это workflow_dispatch, а не repository_dispatch

Оркестратор ходит в другие репозитории под токеном GitHub App
(`create-github-app-token` выпускает установочный токен, scoped под конкретный
репозиторий). У App намеренно **минимальный** набор прав:

| Право | Значение |
|---|---|
| **Actions** | Read and write |
| **Contents** | Read-only |
| **Metadata** | Read-only (обязательное) |

Этого достаточно для всей оркестрации:

| Операция | Требуемое право |
|---|---|
| `gh workflow run` / `createWorkflowDispatch` (запуск workflow) | Actions: **write** |
| `gh run list` / `gh run watch` (поиск и ожидание запуска) | Actions: read |
| `gh repo view --json defaultBranchRef` (ветка по умолчанию) | Metadata: read |

## Ловушка: repository_dispatch требует Contents: write

Изначально `notify` в `rpmbuild-php-8.5` отправлял событие через
`repository_dispatch` (`github.rest.repos.createDispatchEvent`,
`POST /repos/{owner}/{repo}/dispatches`). На первом же живом запуске — **HTTP 403
`Resource not accessible by integration`**. Диагноз в заголовке ответа:

```
x-accepted-github-permissions: contents=write
```

То есть `repository_dispatch` требует **Contents: write** — право, которого у App
нет по замыслу. Выдавать оркестратору, который лишь запускает сборки, доступ на
**запись содержимого репозиториев** — избыточно и небезопасно.

## Решение: только workflow_dispatch

Вместо `repository_dispatch` весь авто-путь использует **workflow_dispatch**, для
которого хватает уже выданного `Actions: write`:

- **`notify`** (в `rpmbuild-php-8.4/build.yaml` и `rpmbuild-php-8.5/build.yaml`)
  вызывает `github.rest.actions.createWorkflowDispatch({ workflow_id: 'php-8.N.yml',
  ref: <ветка по умолчанию pipeline-репозитория> })`. Ветка по умолчанию берётся
  через `github.rest.repos.get` (Metadata: read), а не хардкодится.
- **`dispatch-and-wait`** запускает целевой workflow через `gh workflow run`
  (тот же `createWorkflowDispatch` под капотом) и ждёт результат через
  `gh run watch --exit-status`.

Итог: **ни один авто-триггер в этой системе не использует `repository_dispatch`.**
`php-8.4.yml` и `php-8.5.yml` объявляют только `workflow_dispatch` (ручной
запуск + вызов из `notify`). Единственный оставшийся слушатель
`repository_dispatch` — необязательный `php-base-updated` в `rebuild-family.yml`;
его никто не отправляет. Право `Contents` остаётся read-only.

> Если когда-нибудь понадобится именно `repository_dispatch` (например, чтобы
> развязать триггер от имени workflow), придётся поднять право App до
> `Contents: write` и переустановить/переодобрить App — но по умолчанию мы этого
> избегаем ради минимальных привилегий.

## Симптом → причина (шпаргалка)

- `403 Resource not accessible by integration` + `x-accepted-github-permissions:
  contents=write` при dispatch → пытаешься сделать `repository_dispatch` токеном
  без `Contents: write`. Переходи на `createWorkflowDispatch` (workflow_dispatch).
