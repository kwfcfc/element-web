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

// The webpack production build of element-web is heavy: it wants ~8 GB RAM
// (4 GB risks an out-of-memory) and benefits from 4 CPU cores. Crow labels
// only do exact key/value matching (no ">=8GB"), so we keep the build off
// underpowered agents by *requiring* a label that you must set only on
// capable agents (agent config: WOODPECKER_AGENT_LABELS=tier=large).
local agentLabels = {
  tier: 'medium',
};

// Raise the V8 heap so the webpack build doesn't OOM. Keep this at/below the
// RAM available on a `tier=large` agent (8192 MiB assumes an 8 GB worker).
// local nodeBuildHeapMiB = 8192;

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

  // Only schedule this workflow onto agents carrying all of these labels,
  // which keeps the memory-hungry build away from small workers.
  labels: agentLabels,

  // Shallow clone: element-web has a large history, and we don't need it.
  // The version comes from apps/web/package.json (in the tree), not from
  // `git describe`, so depth=1 with no tags is enough and much faster.
  clone: [
    {
      name: 'clone',
      image: 'codefloe.com/crow-plugins/clone',
      settings: {
        depth: 1,
        tags: false,
      },
    },
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
      // environment: {
      //   // Avoid "JavaScript heap out of memory" during the webpack build.
      //   NODE_OPTIONS: '--max-old-space-size=%d' % nodeBuildHeapMiB,
      // },
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
