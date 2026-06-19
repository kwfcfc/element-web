// Crow CI workflow: publish Element Web to Cloudflare Pages via Direct Upload.
//
// This branch tracks a specific upstream element-web tag. Instead of building
// from source, we download the prebuilt, GPG-signed release tarball from
// upstream, verify its signature, inject our own config + headers, and upload
// the result with wrangler. To follow a newer release, bump `upstreamTag`.
//
// Docs:
//   - https://github.com/element-hq/element-web/blob/develop/docs/install.md
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
// Full node image (buildpack-deps based) ships curl, gnupg and tar, which the
// fetch+verify step needs, plus node/npx for wrangler.
local nodeImage = 'node:24-bookworm';

// The branch on this repo that tracks the upstream tag and triggers a deploy.
local deployBranch = 'pages';

// Cloudflare Pages project name (must already exist, see header).
local projectName = 'element-recursion-link';

// The project's "production branch" on Cloudflare. Passing this value to
// `wrangler --branch` makes the upload a *production* deployment (the live
// site) rather than a preview. It does not need to be a real git branch.
local productionBranch = 'main';

// --- Upstream release we deploy. Bump this single line to track a new tag. ---
local upstreamTag = 'v1.12.21';
local releaseBase = 'https://github.com/element-hq/element-web/releases/download/' + upstreamTag;
local releaseKeyUrl = 'https://packages.element.io/element-release-key.asc';
local tarball = 'element-' + upstreamTag + '.tar.gz';   // element-v1.12.21.tar.gz
local extractedDir = 'element-' + upstreamTag;          // element-v1.12.21/

// We no longer build from source, so a small/medium agent is plenty. Tag your
// capable agents (agent config: WOODPECKER_AGENT_LABELS=tier=medium) so this
// stays off any tier you don't want it on.
local agentLabels = {
  tier: 'medium',
};

// Our two local config files that live next to the web app.
local webDir = 'apps/web';
local configFile = 'config.element.recursion-link.eu.org.json';
local headersFile = '_headers';
local outDir = webDir + '/webapp';

// ---- Helpers ------------------------------------------------------------
local enableCorepack = 'corepack enable';

// ---- Workflow -----------------------------------------------------------
{
  // Only deploy when the tracking branch is pushed, or when a human triggers
  // the pipeline manually from the Crow UI/CLI.
  when: [
    // { event: 'push', branch: deployBranch },
    { event: 'manual' },
  ],

  // Only schedule this workflow onto agents carrying all of these labels.
  labels: agentLabels,

  // Shallow clone: we only need our own config/_headers from this repo, not
  // its history, so depth=1 with no tags is enough and much faster.
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
    /*
      ---- DISABLED: build-from-source ----
      Replaced by fetching the prebuilt upstream release tarball below.
      Uncomment these two steps (and have `fetch-and-verify` depend on `build`
      instead) to go back to building Element Web locally.

    {
      name: 'install',
      image: nodeImage,
      commands: [
        enableCorepack,
        'pnpm install --frozen-lockfile',
      ],
    },

    {
      name: 'build',
      image: nodeImage,
      depends_on: ['install'],
      environment: {
        NODE_OPTIONS: '--max-old-space-size=8192',
      },
      commands: [
        enableCorepack,
        'export VERSION="v$(node -p "require(./apps/web/package.json).version")"',
        'pnpm --filter element-web build',
        'cp apps/web/CONFIG apps/web/webapp/CONFIG',
        'cp apps/web/CONFIG apps/web/webapp/config.json',
        'cp apps/web/_headers apps/web/webapp/_headers',
      ],
    },
    */

    {
      name: 'fetch-and-verify',
      image: nodeImage,
      commands: [
        // Download the prebuilt release tarball and its detached signature.
        'curl -fsSL -o "%s" "%s/%s"' % [tarball, releaseBase, tarball],
        'curl -fsSL -o "%s.asc" "%s/%s.asc"' % [tarball, releaseBase, tarball],
        // Import Element's release signing key and verify the signature.
        // A valid signature makes gpg exit 0 (the untrusted-key warning is
        // expected and harmless); a bad/missing signature fails the step.
        'curl -fsSL "%s" | gpg --import' % releaseKeyUrl,
        'gpg --verify "%s.asc" "%s"' % [tarball, tarball],
        // Unpack -> produces the `element-vX.Y.Z/` directory we will deploy.
        'tar -xzf "%s"' % tarball,
        // Inject our deployment config + security/caching headers.
        // Element loads config.<host>.json first, then falls back to config.json
        // (apps/web/src/vector/getconfig.ts), so we ship it under both names.
        'cp "%s/%s" "%s/%s"' % [webDir, configFile, extractedDir, configFile],
        'cp "%s/%s" "%s/config.json"' % [webDir, configFile, extractedDir],
        // Cloudflare Pages reads a `_headers` file at the root of the upload.
        'cp "%s/%s" "%s/%s"' % [webDir, headersFile, extractedDir, headersFile],
      ],
    },

    {
      name: 'deploy',
      image: nodeImage,
      depends_on: ['fetch-and-verify'],
      // wrangler auto-reads these for non-interactive auth.
      environment: {
        CLOUDFLARE_API_TOKEN: { from_secret: 'cloudflare_api_token' },
        CLOUDFLARE_ACCOUNT_ID: { from_secret: 'cloudflare_account_id' },
      },
      commands: [
        // Use pnpm (via corepack) rather than npx: npm walks up to the monorepo
        // root package.json whose devEngines.packageManager is pnpm and aborts
        // with EBADDEVENGINES. pnpm satisfies that requirement.
        enableCorepack,
        ('pnpm dlx wrangler@4 pages deploy "%s"' % extractedDir) +
        (' --project-name "%s"' % projectName) +
        (' --branch "%s"' % productionBranch) +
        ' --commit-hash "$CI_COMMIT_SHA"' +
        ' --commit-message "$CI_COMMIT_MESSAGE"',
      ],
    },
  ],
}
