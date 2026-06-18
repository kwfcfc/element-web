// Crow CI workflow: build Element Web (apps/web) and publish it to
// Cloudflare Pages via Direct Upload (wrangler).
//
// This branch tracks a specific upstream element-web tag. The version that
// Element shows in Settings is taken from the VERSION env var at build time,
// which we derive from apps/web/package.json (it equals the tracked tag).
//
// Docs:
//   - https://github.com/element-hq/element-web/blob/develop/apps/web/README.md
//   - https://developers.cloudflare.com/pages/get-started/direct-upload/
//   - https://crowci.dev/v5-13/usage/jsonnet/
//   - https://crowci.dev/v5-13/usage/workflow-syntax/
//
// Required Crow secrets (Repository -> Settings -> Secrets):
//   - cloudflare_api_token   : a Cloudflare API token with "Cloudflare Pages: Edit"
//   - cloudflare_account_id  : your Cloudflare account id
//
// One-time setup on Cloudflare (creates the Pages project; safe to run locally):
//   npx wrangler pages project create element-recursion-link --production-branch main

// ---- Configuration ------------------------------------------------------
local nodeImage = 'node:24-bookworm';

// The branch on this repo that tracks the upstream tag and triggers a deploy.
local deployBranch = 'pages';

// Cloudflare Pages project name (must already exist, see header).
local projectName = 'element-recursion-link';

// The project's "production branch" on Cloudflare. Passing this value to
// `wrangler --branch` makes the upload a *production* deployment (the live
// site) rather than a preview. It does not need to be a real git branch.
local productionBranch = 'main';

// Our two local config files that live next to the web app.
local webDir = 'apps/web';
local configFile = 'config.element.recursion-link.eu.org.json';
local headersFile = '_headers';
local outDir = webDir + '/webapp';

// ---- Helpers ------------------------------------------------------------
// Every step needs corepack so the pinned pnpm (packageManager field) is used.
local enableCorepack = 'corepack enable';

// ---- Workflow -----------------------------------------------------------
{
  // Only build & deploy when the tracking branch is pushed, or when a human
  // triggers the pipeline manually from the Crow UI/CLI.
  when: [
    { event: 'push', branch: deployBranch },
    { event: 'manual' },
  ],

  steps: [
    {
      name: 'install',
      image: nodeImage,
      commands: [
        enableCorepack,
        // Workspace install at the monorepo root (apps/web is a workspace pkg).
        'pnpm install --frozen-lockfile',
      ],
    },

    {
      name: 'build',
      image: nodeImage,
      depends_on: ['install'],
      commands: [
        enableCorepack,
        // Surface the tracked upstream version in Element's Settings/`/version`.
        'export VERSION="v$(node -p "require(\'./%s/package.json\').version")"' % webDir,
        'echo "Building Element Web $VERSION"',
        'pnpm --filter element-web build',

        // Inject our deployment config + security/caching headers into the
        // static output that gets uploaded.
        // Element loads config.<host>.json first, then falls back to config.json
        // (apps/web/src/vector/getconfig.ts), so we ship it under both names.
        'cp "%s/%s" "%s/%s"' % [webDir, configFile, outDir, configFile],
        'cp "%s/%s" "%s/config.json"' % [webDir, configFile, outDir],
        // Cloudflare Pages reads a `_headers` file at the root of the upload.
        'cp "%s/%s" "%s/%s"' % [webDir, headersFile, outDir, headersFile],
      ],
    },

    {
      name: 'deploy',
      image: nodeImage,
      depends_on: ['build'],
      // wrangler auto-reads these for non-interactive auth.
      environment: {
        CLOUDFLARE_API_TOKEN: { from_secret: 'cloudflare_api_token' },
        CLOUDFLARE_ACCOUNT_ID: { from_secret: 'cloudflare_account_id' },
      },
      commands: [
        enableCorepack,
        ('npx --yes wrangler@4 pages deploy "%s"' % outDir) +
        (' --project-name "%s"' % projectName) +
        (' --branch "%s"' % productionBranch) +
        ' --commit-hash "$CI_COMMIT_SHA"' +
        ' --commit-message "$CI_COMMIT_MESSAGE"',
      ],
    },
  ],
}
